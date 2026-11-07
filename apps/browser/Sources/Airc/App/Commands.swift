// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import QuartzCore

/// Every browser command with its Arc shortcut (CB-2). The main menu shows them; a key monitor
/// runs them before the page sees the key, so a web page can't swallow ⌘T or ⌃2.
struct BrowserCommand {
    let title: String
    /// Settings → Shortcuts and settings.json know it by this (App/ShortcutCenter.swift); "" for keys that can't be
    /// changed. `key` and `modifiers` are the defaults in the lists below and the user's in `CommandMenus.all`.
    let id: String
    var key: String
    var modifiers: NSEvent.ModifierFlags
    let order: KeyOrder
    let run: (WindowController) -> Void

    /// Who gets the key first when a page has the keyboard (CB-3).
    enum KeyOrder {
        /// ⌘ and ⇧⌘ keys go to the page first (but Chrome's reserved ⌘T ⌘W ⌘N ⌘Q); ⌥ and ⌃ keys to the browser.
        case automatic
        case browserFirst
        /// A ⌥ key editors use too (⌥⌘V is Docs' Paste Formatting).
        case pageFirst
        /// Chrome's delayed keys (⌘← ⌘→): the page and fields first, always; the browser's command runs only when the
        /// engine hands the key back unused (KeyMonitor.pageDidNotUse), with no second-press rule. They have no menu
        /// item: a matching item, even a disabled one, takes the key from our own text fields.
        case afterPage
    }

    init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], id: String = "", order: KeyOrder = .automatic,
         _ run: @escaping (WindowController) -> Void) {
        self.title = title
        self.id = id
        self.key = key
        self.modifiers = modifiers
        self.order = order
        self.run = run
    }

    static func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
    static let left = arrow(NSLeftArrowFunctionKey)
    static let right = arrow(NSRightArrowFunctionKey)
    static let up = arrow(NSUpArrowFunctionKey)
    static let down = arrow(NSDownArrowFunctionKey)
    static let pageUp = arrow(NSPageUpFunctionKey)
    static let pageDown = arrow(NSPageDownFunctionKey)
}

enum CommandMenus {
    /// The app menu's own (Settings → Shortcuts can change them; they aren't the key monitor's, only the menu's).
    static func app() -> [BrowserCommand] {
        [
            BrowserCommand("Settings…", ",", .command, id: "app.settings") { $0.app?.showSettings() },
            BrowserCommand("Import from Another Browser…", id: "app.import") { $0.app?.startOnboarding(mode: .rerun, atImport: true) },
        ]
    }

    static func file() -> [BrowserCommand?] {
        [
            BrowserCommand("New Tab", "t", .command, id: "file.newTab") { $0.openCommandBar(mode: .newTab) },
            BrowserCommand("Open Location…", "l", .command, id: "file.openLocation") { $0.openCommandBar(mode: .editURL) },
            // WIN-7 (Browser/MultiWindow.swift): another window on this Space, with the Command Bar.
            BrowserCommand("New Window", "n", .command, id: "file.newWindow") { $0.app?.openNewWindow(from: $0) },
            // PW-1 (Browser/PrivateWindow.swift): in a private window, ⇧⌘N opens another one of the same profile.
            BrowserCommand("New Private Window", "n", [.command, .shift], id: "file.newPrivateWindow") { c in if let app = c.app { PrivateBrowsing.shared.open(app: app) } },
            BrowserCommand("New Little Arc Window", "n", [.command, .option], id: "file.newLittleArc") { $0.app?.openLittleArc(url: nil) },
            nil,
            // LA-1: these act in a Little Arc window (LittleArcController.handleKey); the main window has nothing to move.
            BrowserCommand("Open in Space", "o", .command, id: "file.openInSpace") { c in if c.peek != nil { c.promotePeek() } else { NSSound.beep() } },
            BrowserCommand("Open in Space…", "o", [.command, .option], id: "file.moveToSpace") { _ in NSSound.beep() },
            nil,
            BrowserCommand("Close Tab", "w", .command, id: "file.closeTab") { $0.closeCurrentTab() },
            BrowserCommand("Close Window", "w", [.command, .shift], id: "file.closeWindow") { $0.window.performClose(nil) },
            // Arc's ⌥⌘W: every other Today tab to the Archive, as Clear does (pinned tabs and Favorites stay).
            BrowserCommand("Close Other Tabs", "w", [.command, .option], id: "file.closeOtherTabs") { $0.clearToday() },
            BrowserCommand("Reopen Closed Tab", "t", [.command, .shift], id: "file.reopenClosedTab") { $0.undo() },
            nil,
            BrowserCommand("Save Page As…", "s", [.command, .shift], id: "file.savePage") { $0.savePage() },
            BrowserCommand("Print…", "p", .command, id: "file.print") { $0.printPage() },
        ]
    }

    static func editExtras() -> [BrowserCommand?] {
        [
            BrowserCommand("Copy URL", "c", [.command, .shift], id: "edit.copyURL") { $0.copyURL() },
            BrowserCommand("Copy URL as Markdown", "c", [.command, .shift, .option], id: "edit.copyURLMarkdown") { $0.copyURLMarkdown() },
            // Arc's ⌥⌘V. Docs uses the same key for Paste Formatting, so the page has it first.
            BrowserCommand("Paste URL in New Tab", "v", [.command, .option], id: "edit.pasteURL", order: .pageFirst) { $0.pasteInNewTab() },
            nil,
            BrowserCommand("Find…", "f", .command, id: "edit.find") { $0.showFind() },
            BrowserCommand("Find Next", "g", .command, id: "edit.findNext") { $0.findAgain(forward: true) },
            BrowserCommand("Find Previous", "g", [.command, .shift], id: "edit.findPrevious") { $0.findAgain(forward: false) },
        ]
    }

    static func view() -> [BrowserCommand?] {
        [
            BrowserCommand("Toggle Sidebar", "s", .command, id: "view.toggleSidebar") { $0.toggleSidebar() },
            BrowserCommand("Reload Page", "r", .command, id: "view.reload") { $0.reloadOrStop() },
            BrowserCommand("Reload Ignoring Cache", "r", [.command, .shift], id: "view.reloadIgnoringCache") { $0.reloadIgnoringCache() },
            nil,
            BrowserCommand("Zoom In", "=", .command, id: "view.zoomIn") { $0.zoom(step: 1); $0.siteControlsDidZoom() },
            BrowserCommand("Zoom Out", "-", .command, id: "view.zoomOut") { $0.zoom(step: -1); $0.siteControlsDidZoom() },
            BrowserCommand("Actual Size", "0", .command, id: "view.actualSize") { $0.zoom(step: 0); $0.siteControlsDidZoom() },
            nil,
            BrowserCommand("Extensions", "e", .command, id: "view.extensions") { $0.showExtensions() },
            BrowserCommand("Site Controls", id: "view.siteControls") { $0.toggleSiteControls() },
            // BST-1. Arc had no shortcut for its Boost editor, so neither does this.
            BrowserCommand("Boost This Site…", id: "view.boost") { $0.showBoostEditor() },
            BrowserCommand("History", "y", .command, id: "view.history") { $0.showHistory() },
            nil,
            BrowserCommand("Developer Tools", "i", [.command, .option], id: "view.devTools") { $0.showDevTools(console: false) },
            BrowserCommand("JavaScript Console", "j", [.command, .option], id: "view.console") { $0.showDevTools(console: true) },
            BrowserCommand("View Source", "u", [.command, .option], id: "view.source") { $0.viewSource() },
        ]
    }

    static func spaces() -> [BrowserCommand?] {
        var c: [BrowserCommand?] = [
            BrowserCommand("New Space…", id: "spaces.new") { $0.openNewSpacePanel() },
            BrowserCommand("Rename Space…", id: "spaces.rename") { $0.renameCurrentSpace() },
            BrowserCommand("Edit Theme Color…", id: "spaces.theme") { $0.editTheme($0.currentSpaceID) },
            BrowserCommand("New Profile…", id: "spaces.newProfile") { $0.openCreateProfile(forSpace: $0.currentSpaceID) },
            nil,
            BrowserCommand("Next Space", BrowserCommand.right, [.command, .option], id: "spaces.next") { $0.switchSpace(offset: 1) },
            BrowserCommand("Previous Space", BrowserCommand.left, [.command, .option], id: "spaces.previous") { $0.switchSpace(offset: -1) },
            nil,
        ]
        for n in 1...9 {
            c.append(BrowserCommand("Space \(n)", "\(n)", .control, id: "spaces.\(n)") { $0.switchToSpace(number: n) })
        }
        c.append(nil)
        c.append(BrowserCommand("Manage Spaces…", id: "spaces.manage") { $0.showManageSpaces() })
        c.append(BrowserCommand("Delete Space…", id: "spaces.delete") { $0.deleteSpace($0.currentSpaceID) })
        return c
    }

    static func tabs() -> [BrowserCommand?] {
        var c: [BrowserCommand?] = [
            BrowserCommand("Pin / Unpin Tab", "d", .command, id: "tabs.pin") { $0.togglePin() },
            BrowserCommand("Add to Favorites", id: "tabs.favorite") { $0.addCurrentToFavorites() },
            BrowserCommand("Clear Today", "k", [.command, .shift], id: "tabs.clearToday") { $0.clearToday() },
            nil,
            BrowserCommand("Next Tab", BrowserCommand.down, [.command, .option], id: "tabs.next") { $0.selectAdjacentTab(1) },
            BrowserCommand("Previous Tab", BrowserCommand.up, [.command, .option], id: "tabs.previous") { $0.selectAdjacentTab(-1) },
            BrowserCommand("Last Used Tab", "\t", .control, id: "tabs.lastUsed") { $0.selectLastTab() },
            nil,
            // SV-1 (spec §2.16b): in a split, ⌘[ / ⌘] move between the panes; elsewhere they're Back and Forward.
            BrowserCommand("Back", "[", .command, id: "tabs.back") { if !$0.focusAdjacentPane(-1) { $0.goBack() } },
            BrowserCommand("Forward", "]", .command, id: "tabs.forward") { if !$0.focusAdjacentPane(1) { $0.goForward() } },
            nil,
            // Arc's split keys: ⌃⇧+ adds a pane, ⌃⇧− closes the focused one, ⌃⇧1–4 focus a pane.
            BrowserCommand("New Split View", "=", [.control, .shift], id: "tabs.newSplit") { $0.newSplitView() },
            BrowserCommand("Close Pane", "-", [.control, .shift], id: "tabs.closePane") { $0.closeFocusedPane() },
            BrowserCommand("Separate All Tabs", id: "tabs.separate") { $0.separateShownSplit() },
        ]
        for n in 1...4 {
            c.append(BrowserCommand("Focus Pane \(n)", "\(n)", [.control, .shift], id: "tabs.pane\(n)") { $0.focusPane(number: n) })
        }
        c.append(nil)
        for n in 1...9 {
            c.append(BrowserCommand(n == 9 ? "Last Sidebar Tab" : "Sidebar Tab \(n)", "\(n)", .command, id: "tabs.sidebar\(n)") { $0.selectTab(number: n) })
        }
        c.append(nil)
        c.append(BrowserCommand("Search Tabs…", "a", [.command, .shift], id: "tabs.search") { $0.openCommandBar(mode: .newTab) })
        c.append(BrowserCommand("Library", "l", [.command, .shift], id: "tabs.library") { $0.showLibrary() })
        c.append(BrowserCommand("Join Next Meeting", "j", [.command, .control], id: "tabs.joinMeeting") { $0.joinNextMeeting() })
        return c
    }

    /// Keys with no menu row of their own (Chrome's hidden ones): their items are hidden but keep their keys.
    static func hidden() -> [BrowserCommand] {
        [
            // Arc's ⌘{ ⌘} (⇧⌘[ ⇧⌘]) and Chrome's ⌃⇟ ⌃⇞, beside ⌥⌘↓ ⌥⌘↑. Chrome reserves tab switching.
            BrowserCommand("Next Tab", "}", [.command, .shift], id: "tabs.next.brace", order: .browserFirst) { $0.selectAdjacentTab(1) },
            BrowserCommand("Previous Tab", "{", [.command, .shift], id: "tabs.previous.brace", order: .browserFirst) { $0.selectAdjacentTab(-1) },
            BrowserCommand("Next Tab", BrowserCommand.pageDown, .control, id: "tabs.next.page") { $0.selectAdjacentTab(1) },
            BrowserCommand("Previous Tab", BrowserCommand.pageUp, .control, id: "tabs.previous.page") { $0.selectAdjacentTab(-1) },
        ]
    }

    /// Keys with no menu item at all.
    static func keysOnly() -> [BrowserCommand] {
        [
            // Chrome's ⌘← ⌘→: Back and Forward, unless a field or the page uses the key (text navigation).
            BrowserCommand("Back", BrowserCommand.left, .command, id: "tabs.back.arrow", order: .afterPage) { $0.goBack() },
            BrowserCommand("Forward", BrowserCommand.right, .command, id: "tabs.forward.arrow", order: .afterPage) { $0.goForward() },
        ]
    }

    /// Every command the key monitor runs, with the user's keys (Settings → Shortcuts).
    static var all: [BrowserCommand] { ShortcutCenter.shared.commands }

    /// The same with today's keys (CB-2), the defaults.
    static var defaults: [BrowserCommand] {
        (file() + editExtras() + view() + spaces() + tabs()).compactMap { $0 } + hidden() + keysOnly()
    }
}

final class CommandMenuItem: NSMenuItem {
    var command: BrowserCommand?
    weak var app: AppDelegate?
    @objc func fire() {
        guard let app, let command else { return }
        // WIN-7: the key browser window's command, else the one used last's; with none open, only the ones that open a
        // window run (AppDelegate.runWithoutWindow).
        let c = app.controller(for: NSApp.keyWindow) ?? app.controller
        let opensWindow = { if let c { command.run(c) } else { app.runWithoutWindow(command) } }
        // A private window takes its own shortcuts and the menu commands that make sense there (PrivateWindow.swift).
        if let p = PrivateBrowsing.shared.window(for: NSApp.keyWindow) {
            // The menu runs it now (a click, or a key the page handed back): not once more when the page's answer comes.
            KeyMonitor.cancelPending(command)
            if let e = NSApp.currentEvent, e.type == .keyDown, p.handleKey(e) { return }
            if p.perform(menuTitle: command.title) { return }
            if ["New Window", "New Little Arc Window"].contains(command.title) { opensWindow() }
            return
        }
        // A Little Arc window takes its own shortcuts; the main window's commands don't reach into it.
        if let little = app.littleArc(for: NSApp.keyWindow) {
            if let e = NSApp.currentEvent, e.type == .keyDown, little.handleKey(e) { return }
            if ["New Window", "New Little Arc Window"].contains(command.title) { opensWindow() }
            return
        }
        guard let c else { return app.runWithoutWindow(command) }
        KeyMonitor.menuFired(command, in: c)
    }
}

enum MainMenu {
    static func build(app: AppDelegate) -> NSMenu {
        ShortcutCenter.shared.attach(settings: app.settings)
        let main = NSMenu()

        let appMenu = NSMenu(title: "Airc")
        appMenu.addItem(withTitle: "About Airc", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        #if canImport(Sparkle)
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: NSSelectorFromString("checkForUpdates:"), keyEquivalent: "")
        updates.target = app.updaterController
        #endif
        appMenu.addItem(.separator())
        for c in CommandMenus.app() { appMenu.addItem(item(c, app)) }
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
        // Chrome's Edit menu: ⇧⌘V, and ⌥⇧⌘V as its alternate. Pages see the key first (Docs, Slack and Notion paste
        // plain text on it themselves); otherwise the focused view pastes without the clipboard's formatting.
        PasteAndMatchStyle.install()
        edit.addItem(withTitle: "Paste and Match Style", action: PasteAndMatchStyle.selector, keyEquivalent: "V")
        let matchStyle = edit.addItem(withTitle: "Paste and Match Style", action: PasteAndMatchStyle.selector, keyEquivalent: "V")
        matchStyle.keyEquivalentModifierMask = [.command, .option]
        matchStyle.isAlternate = true
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
        let tabs = menu("Tabs", CommandMenus.tabs(), app)
        for c in CommandMenus.hidden() {
            let i = item(c, app)
            i.isHidden = true
            i.allowsKeyEquivalentWhenHidden = true
            tabs.addItem(i)
        }
        add(tabs, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
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
        guard let c = c.map(ShortcutCenter.shared.bound) else { return .separator() }
        let (key, mods) = ShortcutCenter.menuEquivalent(c.key, c.modifiers)
        let i = CommandMenuItem(title: c.title, action: #selector(CommandMenuItem.fire), keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.command = c
        i.app = app
        i.target = i
        return i
    }
}

extension WindowController {
    /// ⌥⌘V (Arc): the clipboard's URL, or a search for its text, in a new Today tab.
    func pasteInNewTab() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = URLRules.resolve(text, engine: store.profile(ofSpace: currentSpaceID).searchEngine) else { return NSSound.beep() }
        navigate(to: url, newTab: true, typed: true)
    }

    /// ⌃⌘J (Arc's Live Calendar): the meeting the sidebar offers to join.
    func joinNextMeeting() {
        guard let e = CalendarCenter.shared.promptEvent, e.link != nil else { return NSSound.beep() }
        CalendarCenter.shared.join(e, spaceID: nil, controller: self)
    }
}

/// Edit › Paste and Match Style sends Chrome's `pasteAndMatchStyle:`, which Chromium's page view implements. AppKit's
/// text views (our fields) and WebKit's web view call the same action `pasteAsPlainText:`; they get Chrome's name too.
enum PasteAndMatchStyle {
    static let selector = NSSelectorFromString("pasteAndMatchStyle:")

    /// Our own fields (field editors and the Boost code view are NSTextViews).
    static func install() { add(to: NSTextView.self) }

    /// Gives `cls` a `pasteAndMatchStyle:` that runs its `pasteAsPlainText:`, unless it has one of its own.
    static func add(to cls: AnyClass) {
        let plain = NSSelectorFromString("pasteAsPlainText:")
        guard class_getInstanceMethod(cls, plain) != nil else { return }
        let run: @convention(block) (NSObject, Any?) -> Void = { view, sender in _ = view.perform(plain, with: sender) }
        class_addMethod(cls, selector, imp_implementationWithBlock(run), "v@:@")
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
        let run: () -> Void
        let fallback: DispatchWorkItem
        /// The window whose page has it (the main window, a private window).
        weak var window: NSWindow?
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

    /// Chrome's reserved shortcuts (pages never get them) and ⌥/⌃ combinations stay browser-first. Keys editors use
    /// (⌘B, ⇧⌘V, ⌥⌘V …) are always the page's first, whichever command the user gave them.
    private static func pageMayUse(_ cmd: BrowserCommand) -> Bool {
        switch cmd.order {
        case .browserFirst: return false
        case .pageFirst, .afterPage: return true
        case .automatic:
            if ShortcutCenter.isPageCommon(cmd) { return true }
            guard cmd.modifiers.contains(.command), !cmd.modifiers.contains(.option), !cmd.modifiers.contains(.control) else { return false }
            return !["t", "w", "n", "q"].contains(cmd.key.lowercased())
        }
    }

    /// The same spelling the page script reports (WebKitEngine.keysScript, the engine's TabBridge).
    static func combo(_ cmd: BrowserCommand) -> String {
        (cmd.modifiers.contains(.command) ? "cmd+" : "") + (cmd.modifiers.contains(.control) ? "ctrl+" : "") + (cmd.modifiers.contains(.option) ? "alt+" : "")
            + (cmd.modifiers.contains(.shift) ? "shift+" : "") + cmd.key.lowercased()
    }

    /// The page answered: run the browser's command if it didn't use the shortcut, otherwise wait for a second press.
    static func pageReported(_ combo: String, pageUsedIt: Bool, in c: WindowController) {
        pageReported(combo, pageUsedIt: pageUsedIt, window: c.window)
    }

    /// The same for the page of `window` (a private window's).
    static func pageReported(_ combo: String, pageUsedIt: Bool, window: NSWindow) {
        // ⇧ shortcuts arrive from the page with an upper-case or shifted key; match on what we're waiting for.
        guard let key = pending.keys.first(where: { $0 == combo || $0.lowercased() == combo.lowercased() }),
              pending[key]?.window === window, let p = pending.removeValue(forKey: key) else { return }
        p.fallback.cancel()
        if pageUsedIt { pageUsed[key] = CACurrentMediaTime() } else { p.run() }
    }

    /// The menu ran a command (a click, or the engine handing back a key the page didn't use): run it once.
    static func menuFired(_ cmd: BrowserCommand, in c: WindowController) {
        cancelPending(cmd)
        cmd.run(c)
    }

    /// `cmd` runs from elsewhere (its menu): the page's answer no longer runs it.
    static func cancelPending(_ cmd: BrowserCommand) {
        if let p = pending.removeValue(forKey: combo(cmd)) { p.fallback.cancel() }
    }

    /// Hands `cmd`'s key to the focused page first (true), or returns false when the browser's command runs now.
    private static func offerToPage(_ cmd: BrowserCommand, in c: WindowController) -> Bool {
        offerToPage(cmd, page: c.focusedPage, engine: c.app?.engine, window: c.window) { [weak c] in if let c { cmd.run(c) } }
    }

    /// The same for any window's focused page; `run` is that window's command for the key.
    static func offerToPage(_ cmd: BrowserCommand, page: EngineTab?, engine: BrowserEngine?, window: NSWindow,
                            run: @escaping () -> Void) -> Bool {
        guard pageMayUse(cmd), engine?.reportsPageShortcuts == true, let page,
              let scheme = page.url?.scheme, ["http", "https", "file", "data"].contains(scheme) else { return false }
        let key = combo(cmd)
        if let t = pageUsed.removeValue(forKey: key), CACurrentMediaTime() - t < secondPressWindow { return false }
        pending[key]?.fallback.cancel()
        // No answer (a page the script couldn't reach, a hung renderer): the browser's command runs anyway.
        let fallback = DispatchWorkItem {
            guard let p = pending.removeValue(forKey: key) else { return }
            p.run()
        }
        pending[key] = Pending(run: run, fallback: fallback, window: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + pageAnswerTimeout, execute: fallback)
        return true
    }

    static func install(app: AppDelegate) -> Any? {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak app] event in
            if event.charactersIgnoringModifiers?.lowercased() == "q" { quitHold?.cancel(); quitHold = nil }
            if event.keyCode == 53 { (app?.controller(for: event.window) ?? app?.controller)?.fullScreen.escapeUp() }
            return event
        }
        let handle: (NSEvent) -> NSEvent? = { [weak app] event in
            guard let app else { return event }
            var mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
                #if AIRC_TESTING
                let automated = app.options.isAutomated && !testQuitHold
                #else
                let automated = app.options.isAutomated
                #endif
                guard !event.isARepeat, quitHold == nil, !automated else { return nil }
                (app.controller(for: event.window) ?? app.controller)?.showToast("Hold ⌘Q to Quit")
                let code = event.keyCode
                let work = DispatchWorkItem {
                    quitHold = nil
                    // Chromium's application class sends ⌘ key-ups straight to the window, past the key-up monitor
                    // above, so the key itself decides: still down after 0.7 s is a hold.
                    if quitIsHeld(code) { quit() }
                }
                quitHold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                return nil
            }
            if let little = app.littleArc(for: event.window) { return little.handleKey(event) ? nil : event }
            if let p = PrivateBrowsing.shared.window(for: event.window) {
                // WebKit handed back a key its page didn't use: the menus take it now (CommandMenuItem.fire).
                if event === offered { offered = nil; return event }
                return p.handleKeyPageFirst(event) ? nil : event
            }
            // WIN-7: the browser window the key is for.
            guard let c = app.controller(for: event.window) else { return event }
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
            // WebKit hands a key back through NSApp.sendEvent when the page didn't use it. The menus take it now (a
            // command runs once, from its menu item); it isn't offered to the page a second time.
            if event === offered {
                offered = nil
                return pageDidNotUse(event) ? nil : event
            }
            let editingText = c.window.firstResponder is NSTextView
            // ⌘Z: a field being edited, ours or the page's, undoes its own typing (Docs, every web form). A page with
            // the keyboard elsewhere gets the key first (Figma's canvas undoes itself); otherwise ⌘Z restores closed
            // tabs (SB-23, SB-40), or runs the command the user gave ⌘Z (Settings → Shortcuts).
            if chars == "z", mods == .command {
                if editingText || pageIsEditingText(page: c.focusedPage, in: c.window) { return event }
                if !ShortcutCenter.shared.owns(chars, mods) {
                    if offerToPage(reopenOnUndo, in: c) { deliverToPage(event, in: c.window); return nil }
                    c.undo()
                    return nil
                }
            }
            for cmd in CommandMenus.all where !cmd.key.isEmpty {
                guard cmd.key.lowercased() == chars, cmd.modifiers == mods else { continue }
                // Plain editing shortcuts belong to the field being edited.
                if editingText, mods == .command, ["a", "c", "v", "x"].contains(chars) { return event }
                if cmd.order == .afterPage {
                    // Our field's (text navigation), or the page's: an unused key comes back (pageDidNotUse).
                    if editingText { return event }
                    if c.focusedPage != nil { deliverToPage(event, in: c.window); return nil }
                    cmd.run(c)
                    return nil
                }
                if offerToPage(cmd, in: c) {
                    deliverToPage(event, in: c.window)
                    return nil
                }
                cmd.run(c)
                return nil
            }
            return event
        }
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let passed = handle(event) else { return nil }
            #if AIRC_TESTING
            if testKeyWindowDispatch?(passed) == true { return nil }
            #endif
            return passed
        }
    }

    /// ⌘Q is still held (the Q key and ⌘ are down), and the quit itself: the shortcuts check stands in for both.
    static var quitIsHeld: (UInt16) -> Bool = { code in
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) && NSEvent.modifierFlags.contains(.command)
    }
    static var quit: () -> Void = { NSApp.terminate(nil) }

    #if AIRC_TESTING
    /// The shortcuts check (ShortcutsCheck.swift): AppKit's dispatch for a key window, after this monitor, for a test
    /// window that can't be key. True: it took the event.
    static var testKeyWindowDispatch: ((NSEvent) -> Bool)?
    /// The shortcuts check: hold to quit in an automated run (which otherwise ignores ⌘Q).
    static var testQuitHold = false
    #endif

    /// The engine hands back a key the page didn't use (Chromium's unhandled-key callback, WebKit's resend): Chrome's
    /// delayed keys (⌘← ⌘→) run their command now. True: one ran.
    static func pageDidNotUse(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let c = (NSApp.delegate as? AppDelegate)?.controller(for: event.window),
              let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let cmd = CommandMenus.all.first(where: { $0.order == .afterPage && $0.key == chars && $0.modifiers == mods }) else { return false }
        cmd.run(c)
        return true
    }

    /// ⌘Z outside a text field (Arc): Reopen Closed Tab, after the page had its chance (CB-3).
    private static let reopenOnUndo = BrowserCommand("Reopen Closed Tab", "z", .command) { $0.undo() }

    /// The key went to the page (offerToPage); WebKit may send it back (`offered`).
    private static weak var offered: NSEvent?

    /// Straight to the page, whatever AppKit's own order (the main menu could otherwise take it first).
    static func deliverToPage(_ event: NSEvent, in window: NSWindow) {
        offered = event
        if let r = window.firstResponder as? NSView, !r.performKeyEquivalent(with: event) { r.keyDown(with: event) }
    }

    /// A field in the page has the keyboard: Chromium's page view and WebKit's web view have a text input context
    /// only then.
    static func pageIsEditingText(_ c: WindowController) -> Bool { pageIsEditingText(page: c.focusedPage, in: c.window) }

    static func pageIsEditingText(page: EngineTab?, in window: NSWindow) -> Bool {
        page != nil && (window.firstResponder as? NSView)?.inputContext != nil
    }
}

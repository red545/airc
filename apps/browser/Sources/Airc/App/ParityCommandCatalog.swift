// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI

/// C04 and E14 (Arc's TypeTravel and Help menu): every command in the menu bar can be found by typing in the Command Bar,
/// by its title, its menu and a few other words for it (Arc's aliases, in Airc's own words), enabled as the menu would
/// be. The Help menu has Getting Started, Essential Keyboard Shortcuts (the person's own keys, as Settings → Shortcuts
/// has them), Release Notes and the Privacy Policy; macOS adds its search field, which finds any menu item.
enum ParityCommandCatalog {
    // MARK: Help

    static let gettingStarted = URL(string: "https://aircbrowser.com/features")!
    static let releaseNotes = URL(string: "https://aircbrowser.com/changelog")!
    static let privacyPolicy = URL(string: "https://aircbrowser.com/privacy")!

    static func help() -> [BrowserCommand?] {
        [
            BrowserCommand("Getting Started", id: "help.gettingStarted") { $0.openHelpPage(gettingStarted) },
            BrowserCommand("Essential Keyboard Shortcuts", id: "help.shortcuts") { EssentialShortcutsWindow.show(over: $0.window) },
            nil,
            BrowserCommand("Release Notes", id: "help.releaseNotes") { $0.openHelpPage(releaseNotes) },
            BrowserCommand("Privacy Policy", id: "help.privacy") { $0.openHelpPage(privacyPolicy) },
            BrowserCommand("Open Task Manager", id: "help.taskManager") { $0.openTaskManager() },   // P20d: Help › Troubleshooting
        ]
    }

    // MARK: Essential keys

    /// The shortcuts overview: Arc's essentials, by what they're for. Each shows the key it has now (remapped or not);
    /// one the person took away isn't listed.
    static let essentials: [(title: String, ids: [String])] = [
        ("Tabs", ["file.newTab", "file.closeTab", "file.reopenClosedTab", "tabs.pin", "tabs.lastUsed", "tabs.next", "tabs.previous",
                  "tabs.clearToday", "tabs.revealCurrent"]),
        ("Spaces and windows", ["spaces.next", "spaces.previous", "file.newWindow", "file.newPrivateWindow", "file.newLittleArc",
                                "view.toggleSidebar", "tabs.library"]),
        ("Pages", ["file.openLocation", "edit.copyURL", "edit.copyURLMarkdown", "edit.copyURLQuote", "edit.find", "view.reload",
                   "view.capture", "view.showToolbar"]),
        ("Split View", ["tabs.newSplit", "tabs.closePane", "tabs.previousPane", "tabs.nextPane"]),
        ("Notes and meetings", ["file.newNote", "tabs.joinMeeting"]),
        ("Numbers", ["tabs.sidebar1", "tabs.sidebar9", "spaces.1"]),
    ]

    /// `essentials` with today's keys: (section, [(title, keys)]).
    static func essentialRows() -> [(title: String, rows: [(title: String, keys: String)])] {
        let byID = Dictionary(CommandMenus.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sections: [(title: String, rows: [(title: String, keys: String)])] = []
        for section in essentials {
            var rows: [(title: String, keys: String)] = []
            for id in section.ids {
                guard let c = byID[id], !c.key.isEmpty,
                      let k = ShortcutCenter.combo(c.key, c.modifiers) else { continue }
                if id == "tabs.sidebar1", k.display == "⌘1" {
                    rows.append(("Sidebar Tabs 1–8", "⌘1–8"))
                } else if id == "spaces.1", k.display == "⌃1" {
                    rows.append(("Spaces 1–9", "⌃1–9"))
                } else {
                    rows.append((c.title, k.display))
                }
            }
            if !rows.isEmpty { sections.append((section.title, rows)) }
        }
        return sections
    }

    // MARK: The menu bar in the Command Bar

    /// A menu item the Command Bar can offer, with its menu path ("Edit", "Speech").
    struct Entry {
        let path: [String]
        let item: NSMenuItem
    }

    /// Items the Command Bar leaves out: plain editing (the bar's own field would get it), the app's housekeeping, and
    /// the commands that open the bar itself.
    static let leftOut: Set<String> = [
        "Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All", "Quit Airc", "Hide Airc",
        "Hide Others", "Show All", "New Tab", "Open Location…", "Search Tabs…", "Minimize", "Zoom", "Bring All to Front",
        // The Command Bar has these as Show/Hide, Pin/Unpin, Reload and Add Split View already.
        "Show Toolbar", "Toggle Sidebar", "Pin / Unpin Tab", "Reload Page", "New Split View",
        // …and Separate Tab from Split and Expand / Restore Current Split (SplitActions.splitCommandActions).
        "Separate Page from Split View", "Expand Current Split", "Restore Current Split",
    ]

    /// Other words for some commands, so typing what you mean finds them.
    static let aliases: [String: [String]] = [
        "Copy URL": ["copy link", "link", "address"],
        "Copy URL as Quote": ["copy quote", "highlight", "selection"],
        "Use Selection to Find": ["find selection", "search selected"],
        "Jump to Selection": ["scroll to selection", "selected"],
        "Start Speaking": ["read aloud", "speak", "voice", "say"],
        "Stop Speaking": ["quiet", "silence"],
        "Show Spelling and Grammar": ["spell check", "spelling", "typos"],
        "Check Document Now": ["spell check", "spelling"],
        "Make Upper Case": ["uppercase", "capitals", "caps"],
        "Make Lower Case": ["lowercase"],
        "Release Notes": ["changelog", "what's new", "updates", "version"],
        "Essential Keyboard Shortcuts": ["keys", "keyboard", "shortcuts", "cheat sheet", "hotkeys"],
        "Getting Started": ["welcome", "tour", "help", "learn"],
        "Privacy Policy": ["privacy", "data"],
        "Check for Updates…": ["update", "upgrade", "version"],
        "Settings…": ["preferences", "options"],
        "Show Toolbar": ["address bar", "url bar"],
        "Toggle Sidebar": ["hide sidebar", "show sidebar"],
        "Reload Ignoring Cache": ["hard reload", "force refresh"],
        "New Private Window": ["incognito"],
        "New Little Airc Window": ["mini window", "little arc"],
        "Capture…": ["screenshot"],
        "Developer Tools": ["inspect", "devtools", "web inspector"],
        "Bold": ["format"], "Italic": ["format"], "Underline": ["format"],
    ]

    /// Every menu-bar command worth offering, depth first, in menu order.
    static func entries(of menu: NSMenu?, path: [String] = []) -> [Entry] {
        guard let menu else { return [] }
        var out: [Entry] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate && item.view == nil {
            if let sub = item.submenu {
                // The Window menu lists windows by name; Share's submenu is the system's.
                if path.isEmpty && sub === NSApp.windowsMenu { continue }
                if SelectionShare.of(item) != nil { continue }
                out += entries(of: sub, path: path + [path.isEmpty ? sub.title : item.title])
                continue
            }
            guard item.action != nil, !leftOut.contains(item.title), !isNumbered(item.title) else { continue }
            out.append(Entry(path: path, item: item))
        }
        return out
    }

    /// "Space 3", "Sidebar Tab 2", "Focus Pane 1": one of a numbered run, which ⌃/⌘ digits cover.
    static func isNumbered(_ title: String) -> Bool {
        title.last?.isNumber == true && title.dropLast().last == " "
    }

    static func keys(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var mods = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key != key.lowercased() { mods.insert(.shift); key = key.lowercased() }
        return ShortcutCenter.combo(key, mods)?.display ?? ""
    }

    /// The last list made, for the keys typed in the same second.
    static var cache: (window: ObjectIdentifier, at: CFTimeInterval, actions: [WindowController.CommandAction])?
}

extension WindowController {
    /// Help's pages (Getting Started, Release Notes, the Privacy Policy): a new tab in this Space.
    func openHelpPage(_ url: URL) { navigate(to: url, newTab: true) }

    /// C04: the menu bar's commands for the Command Bar, the ones it doesn't offer under the same name already, as the
    /// menus would enable them in this window. Choosing one is choosing it in its menu, once the bar has closed.
    /// Built at most once a second (the bar asks on every key).
    func menuCommandActions(excluding taken: Set<String>) -> [CommandAction] {
        let now = CACurrentMediaTime()
        if let c = ParityCommandCatalog.cache, c.window == ObjectIdentifier(window), now - c.at < 1 {
            return (c.actions + blockingCommandActions()).filter { !taken.contains($0.title) }
        }
        let entries = ParityCommandCatalog.entries(of: NSApp.mainMenu)
        Set(entries.compactMap(\.item.menu)).forEach { $0.update() }
        let actions: [CommandAction] = entries.compactMap { e in
            guard menuItemWorksHere(e.item) else { return nil }
            let item = e.item, title = item.title
            var words = e.path.map { $0.lowercased() }
            words += ParityCommandCatalog.aliases[title] ?? []
            return CommandAction(title: title, symbol: "filemenu.and.selection", hint: ParityCommandCatalog.keys(of: item), keywords: words) { [weak item] in
                // After the bar has closed and the page (or note) has the keyboard back.
                DispatchQueue.main.async {
                    guard let item, let menu = item.menu, let i = menu.items.firstIndex(of: item) else { return }
                    menu.update()
                    if item.isEnabled { menu.performActionForItem(at: i) } else { NSSound.beep() }
                }
            }
        }
        ParityCommandCatalog.cache = (ObjectIdentifier(window), now, actions)
        return (actions + blockingCommandActions()).filter { !taken.contains($0.title) }
    }

    /// Whether choosing `item` does something once the bar has closed and the note or page has the keyboard again:
    /// Airc's own commands as their menu validates them; the Mac's editing commands (sent to whatever has the keyboard)
    /// when the note, or a view of the page, on screen answers them; Format's traits in a note.
    func menuItemWorksHere(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if item.target is FormatRouter { return peek == nil && shownNote != nil }
        if let v = item.target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if item.target != nil { return true }
        // The window's and the app's own (Enter Full Screen, About Airc).
        if window.responds(to: action) || NSApp.responds(to: action) || (NSApp.delegate as AnyObject?)?.responds(to: action) == true { return true }
        if peek == nil, let note = shownNote { return note.textView.responds(to: action) }
        guard let page = displayedLinkPage else { return false }
        return NativeEditingMenus.responder(for: action, under: page.view) != nil
    }
}

// MARK: Essential Keyboard Shortcuts

/// Help › Essential Keyboard Shortcuts: a window of the keys that matter most, as the person has them now. Not a
/// panel above other apps: an ordinary window of Airc's, one at a time.
enum EssentialShortcutsWindow {
    private static var window: NSWindow?

    static func show(over parent: NSWindow?) {
        if let w = window { w.contentViewController = NSHostingController(rootView: EssentialShortcutsView(sections: ParityCommandCatalog.essentialRows())); w.makeKeyAndOrderFront(nil); return }
        let w = makeWindow()
        if let p = parent?.frame {
            w.setFrameOrigin(NSPoint(x: p.midX - w.frame.width / 2, y: p.midY - w.frame.height / 2))
        } else {
            w.center()
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// The window, not yet shown (the P01 check and the marketing shot draw it off screen).
    static func makeWindow() -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: EssentialShortcutsView(sections: ParityCommandCatalog.essentialRows())))
        w.title = "Essential Keyboard Shortcuts"
        // The title is in the content, under the window's buttons (as Arc's own panels have it).
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        return w
    }
}

struct EssentialShortcutsView: View {
    let sections: [(title: String, rows: [(title: String, keys: String)])]

    /// The sections in two columns of about the same height.
    private var columns: [[(title: String, rows: [(title: String, keys: String)])]] {
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        // In order: the left column takes sections while they keep it nearer half than not.
        var split = 0, used = 0
        for s in sections {
            guard used + (s.rows.count + 2) / 2 <= total / 2 else { break }
            used += s.rows.count + 2
            split += 1
        }
        return [Array(sections.prefix(split)), Array(sections.dropFirst(split))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Essential Keyboard Shortcuts").font(.system(size: 20, weight: .semibold, design: .rounded))
            HStack(alignment: .top, spacing: 36) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(s.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                                    HStack(spacing: 16) {
                                        Text(r.title).font(.system(size: 13))
                                        Spacer(minLength: 12)
                                        Text(r.keys).font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 250)
                }
            }
            Text("Change any of them in Settings → Shortcuts.").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)   // under the window's buttons: the title bar's own height is the view's top inset
        .padding(.bottom, 24)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

// P20d: Arc 1.171's developer commands in the menu bar, read from its MainMenu.nib.
//   View: … Reload Ignoring Cache, Clear Cookies and Refresh, Clear Cache and Refresh (no keys).
//   View › Developer: View Source ⌥⌘U, Developer Tools ⌥⌘I, Inspect Elements ⌥⌘C, JavaScript Console ⌥⌘J,
//     Network Inspector, Developer Mode ⌃D.
//   Help › Troubleshooting: Open Task Manager (TaskManager/).
// The commands are in CommandMenus.view() and ParityCommandCatalog.help(), so Settings › Shortcuts and settings.json
// know them by id; `DeveloperMenus.arrange` moves them into Arc's submenus. The Command Bar finds them in the menu bar.
// Each acts on the page on screen in the window in front, a private window's too: its own DevTools, its own session's
// cookies and cache (never the regular profile's).

enum DeveloperMenus {
    /// View › Developer, in Arc's order.
    static let developerIDs = ["view.source", "view.devTools", "view.inspectElements", "view.console",
                               "view.networkInspector", "view.developerSite"]
    static let troubleshootingIDs = ["help.taskManager"]

    /// From MainMenu.build, once View and Help have their items.
    static func arrange(view: NSMenu, help: NSMenu) {
        nest(developerIDs, in: view, title: "Developer")
        nest(troubleshootingIDs, in: help, title: "Troubleshooting")
    }

    /// The items with these ids go into a submenu called `title`, in this order, where the topmost of them was, after a
    /// separator.
    private static func nest(_ ids: [String], in menu: NSMenu, title: String) {
        let items = ids.compactMap { id in menu.items.first { ($0 as? CommandMenuItem)?.command?.id == id } }
        // Every item moved is at or after the first of them, so its index still holds afterwards.
        guard var at = items.compactMap({ menu.items.firstIndex(of: $0) }).min() else { return }
        let sub = NSMenu(title: title)
        for i in items { menu.removeItem(i); sub.addItem(i) }
        at = min(at, menu.items.count)
        if at > 0, !menu.items[at - 1].isSeparatorItem { menu.insertItem(.separator(), at: at); at += 1 }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = sub
        menu.insertItem(holder, at: at)
    }
}

/// The commands themselves, for a main window's page and a private window's alike.
enum DeveloperCommands {
    /// Inspect Elements (DevTools on Elements, picking an element) and Network Inspector. Safari's engine can't choose
    /// a panel: Web Inspector opens instead (its own toggle, so not when it's open already).
    static func show(_ panel: EngineDevToolsPanel, on page: EngineTab?, toast: @escaping (String) -> Void) {
        guard let page, !page.isClosed else { return NSSound.beep() }
        let done: (Result<Void, EngineDeveloperError>) -> Void = { [weak page] result in
            guard case .failure(let error) = result else { return }
            if case .unavailable = error, let page, page.isDevToolsOpen || page.showDevTools(console: false) {
                if panel == .network { toast("Web Inspector is open: its Network tab has the page's requests") }
                return
            }
            toast(error.localizedDescription)
        }
        if panel == .elements { page.inspectElements(completion: done) } else { page.showDevTools(panel: panel, completion: done) }
    }

    /// Clear Cookies and Refresh / Clear Cache and Refresh: only that, for the page's site and its subdomains, in the
    /// page's own store, then a reload.
    static func clear(_ types: Set<EngineSiteDataType>, on page: EngineTab?, toast: @escaping (String) -> Void) {
        guard let page, !page.isClosed, let url = page.url, ["http", "https"].contains(url.scheme ?? "") else {
            NSSound.beep()
            return toast("Clearing cookies or cache is for web pages")
        }
        let what = types == [.cookies] ? "cookies" : types == [.cache] ? "cache" : "cookies and cache"
        page.developerSiteDomain { [weak page] domain in
            guard let page else { return }
            let site = (try? domain.get()) ?? url.host ?? url.absoluteString
            page.clearSiteData(types, reload: true) { result in
                switch result {
                case .success: toast("Cleared \(what) for \(site) and refreshed")
                case .failure(let error): toast(error.localizedDescription)
                }
            }
        }
    }
}

extension WindowController {
    private var developerCommandPage: EngineTab? { shownTabID.flatMap { engineTab(for: $0) } }

    func inspectElements() { DeveloperCommands.show(.elements, on: developerCommandPage) { [weak self] in self?.showToast($0) } }
    func showNetworkInspector() { DeveloperCommands.show(.network, on: developerCommandPage) { [weak self] in self?.showToast($0) } }
    func clearSiteDataAndRefresh(_ types: Set<EngineSiteDataType>) {
        DeveloperCommands.clear(types, on: developerCommandPage) { [weak self] in self?.showToast($0) }
    }
    func openTaskManager() { TaskManagerWindow.show(from: window, app: app) }
}

extension PrivateWindowController {
    /// The developer commands a private window runs on its own page (perform(menuTitle:) hands them here).
    func performDeveloperCommand(_ title: String) -> Bool {
        let toast: (String) -> Void = { [weak self] in self?.showToast($0) }
        switch title {
        case "Inspect Elements": DeveloperCommands.show(.elements, on: shownPage, toast: toast)
        case "Network Inspector": DeveloperCommands.show(.network, on: shownPage, toast: toast)
        case "Clear Cookies and Refresh": DeveloperCommands.clear([.cookies], on: shownPage, toast: toast)
        case "Clear Cache and Refresh": DeveloperCommands.clear([.cache], on: shownPage, toast: toast)
        case "Open Task Manager": TaskManagerWindow.show(from: window, app: app)
        default: return false
        }
        return true
    }
}

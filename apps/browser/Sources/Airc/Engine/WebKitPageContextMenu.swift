// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import WebKit

/// AppKit's public menu hook runs for page, link, image and selection menus.
final class PageMenuWebView: WKWebView {
    weak var pageTab: WebKitTab?
    /// The link of the last context menu (WebKitProfile.contextLinkScript); nil off a link.
    fileprivate(set) var contextLink: URL?
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        appendPageItems(to: menu)
        #if AIRC_TESTING
        testMenuOpened?(menu)
        #endif
    }
    #if AIRC_TESTING
    var testMenuOpened: ((NSMenu) -> Void)?
    #endif
    func appendPageItems(to menu: NSMenu) {
        guard let tab = pageTab else { return }
        retargetSearchItem(in: menu, tab: tab)
        insertLinkSpaces(in: menu, tab: tab)
        // WebKit's menu on selected text has its Copy (C06's Copy Quote Link goes right after it, as in Chromium's).
        let copy = menu.items.firstIndex { $0.identifier == Self.copyItem }
        var items = tab.delegate?.tab(tab, pageMenu: copy == nil ? [:] : ["hasSelection": true]) ?? []
        if let copy, let quote = items.firstIndex(where: { $0["id"] == QuoteLinkMenu.id }), let title = items[quote]["title"] {
            menu.insertItem(PageCaptureMenuItem(title: title, id: QuoteLinkMenu.id, tab: tab), at: copy + 1)
            items.remove(at: quote)
        }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        for item in items {
            guard let title = item["title"], let id = item["id"] else { continue }
            menu.addItem(PageCaptureMenuItem(title: title, id: id, tab: tab))
        }
    }
}

extension PageMenuWebView {
    /// WebKit's link items: a menu with one of them is a link's menu.
    static let openLinkItems = ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"].map { NSUserInterfaceItemIdentifier(rawValue: $0) }
    static let linkSpacesItem = NSUserInterfaceItemIdentifier("AircOpenLinkInSpace")
    static let linkSpacesTitle = "Open Link in Space"

    /// The page script's report of the link a `contextmenu` event was for (WebKitProfile.contextLinkScript).
    func noteContextLink(_ href: String) {
        contextLink = URL(string: href).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    /// SP-31 "Open Link in Space ›", after WebKit's "Open Link in New Window", as Chromium's menu has it: the
    /// delegate's Spaces (none in a private window or Little Airc, so no item). The link is read when a Space is
    /// chosen: the page's report arrives before the menu, but nothing here depends on that order.
    func insertLinkSpaces(in menu: NSMenu, tab: WebKitTab) {
        guard let anchor = menu.items.firstIndex(where: { item in item.identifier.map { Self.openLinkItems.contains($0) } ?? false }),
              let spaces = tab.delegate?.linkSpaces(for: tab), !spaces.isEmpty else { return }
        let sub = NSMenu(title: Self.linkSpacesTitle)
        for space in spaces.prefix(100) {
            guard let title = space["title"], let id = space["id"] else { continue }
            sub.addItem(LinkSpaceMenuItem(title: title, spaceID: id, pageView: self))
        }
        let item = NSMenuItem(title: Self.linkSpacesTitle, action: nil, keyEquivalent: "")
        item.identifier = Self.linkSpacesItem
        item.submenu = sub
        let open = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }
        menu.insertItem(item, at: (open ?? anchor) + 1)
    }

    /// WebKit's Copy, in its menu on selected text.
    static let copyItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")

    /// WebKit's identifier for its "Search with Google" item (WKMenuItemIdentifierSearchWeb).
    static let searchWebItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")

    /// C08: WebKit's "Search with Google" asks the system (Safari's engine, often in Safari). It searches the profile's
    /// default search here, in a new tab, and says which engine: "Search with DuckDuckGo".
    func retargetSearchItem(in menu: NSMenu, tab: WebKitTab) {
        guard let item = menu.items.first(where: { $0.identifier == Self.searchWebItem }),
              let name = tab.delegate?.selectionSearchName(for: tab) else { return }
        let search = SelectionSearchItem(title: "Search with \(name)", tab: tab)
        search.identifier = Self.searchWebItem
        menu.insertItem(search, at: menu.index(of: item))
        menu.removeItem(item)
    }
}

/// The page's selection, read when the item is chosen, searched through the delegate's selection-search command.
private final class SelectionSearchItem: NSMenuItem {
    weak var pageTab: EngineTab?
    init(title: String, tab: EngineTab) {
        pageTab = tab
        super.init(title: title, action: #selector(search(_:)), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func search(_ sender: NSMenuItem) {
        guard let tab = pageTab else { return }
        tab.evaluate("String(window.getSelection ? window.getSelection() : '')") { [weak tab] value in
            guard let tab, let text = value as? String, let q = SelectionSearch.query(text) else { return }
            tab.delegate?.tab(tab, pageMenuCommand: SelectionSearchMenu.prefix + q)
        }
    }
}

/// A dedicated action target avoids WKWebView's validation of editing commands.
private final class PageCaptureMenuItem: NSMenuItem {
    weak var pageTab: EngineTab?
    init(title: String, id: String, tab: EngineTab) {
        pageTab = tab
        super.init(title: title, action: #selector(runPageItem(_:)), keyEquivalent: "")
        representedObject = id
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runPageItem(_ sender: NSMenuItem) {
        guard let tab = pageTab, let id = sender.representedObject as? String else { return }
        tab.delegate?.tab(tab, pageMenuCommand: id)
    }
}

/// One Space of "Open Link in Space ›".
private final class LinkSpaceMenuItem: NSMenuItem {
    weak var pageView: PageMenuWebView?
    init(title: String, spaceID: String, pageView: PageMenuWebView) {
        self.pageView = pageView
        super.init(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
        representedObject = spaceID
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let pageView, let tab = pageView.pageTab, let url = pageView.contextLink,
              let id = sender.representedObject as? String else { return }
        tab.delegate?.tab(tab, openLink: url, inSpace: id)
    }
}

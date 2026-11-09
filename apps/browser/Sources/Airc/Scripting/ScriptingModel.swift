// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// K07: what AppleScript sees (Arc's dictionary, apps/browser/Resources/Airc.sdef): the application's windows, a
/// window's spaces and tabs, a space's tabs. The objects are made fresh for each script command and name the live
/// model (WindowController, PrivateWindowController, the store's items and tabs); nothing here is stored.
///
/// A tab is a sidebar row as Arc counted them: a Favorite ("topApp"), a pinned tab ("pinned", in folders and pinned
/// splits too) or a Today tab ("unpinned"). A Favorite or pinned tab's ID is its item's, so it stays the same while
/// the page unloads and loads; a Today tab's is its tab's. A private window's pages are its tabs.
@objc(AircScriptWindow)
final class ScriptWindow: NSObject {
    private weak var browser: WindowController?
    private weak var privateWindow: PrivateWindowController?

    init(_ c: WindowController) { browser = c }
    init(private w: PrivateWindowController) { privateWindow = w }

    var controller: WindowController? { browser }
    var privateController: PrivateWindowController? { privateWindow }
    var nsWindow: NSWindow? { browser?.window ?? privateWindow?.window }
    var store: SpacesStore? { browser?.store ?? privateWindow?.app?.store }

    /// Every browser and private window, front to back (minimized and hidden ones last). Little Arc windows aren't
    /// windows here; a script makes one with `make new tab` at the application.
    static func all(_ app: AppDelegate) -> [ScriptWindow] {
        var out: [ScriptWindow] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ w: NSWindow?) {
            guard let w, !seen.contains(ObjectIdentifier(w)) else { return }
            if let c = app.controller(for: w) { out.append(ScriptWindow(c)) }
            else if let p = PrivateBrowsing.shared.window(for: w) { out.append(ScriptWindow(private: p)) }
            else { return }
            seen.insert(ObjectIdentifier(w))
        }
        NSApp.orderedWindows.forEach(add)
        app.controllers.forEach { add($0.window) }
        PrivateBrowsing.shared.windows.forEach { add($0.window) }
        return out
    }

    // MARK: Properties (Arc's names in Airc.sdef)

    @objc var uniqueID: String { nsWindow.map { String($0.windowNumber) } ?? "" }
    @objc var title: String { nsWindow?.title ?? "" }
    @objc var orderedIndex: Int {
        get {
            guard let app = NSApp.delegate as? AppDelegate else { return 0 }
            return (ScriptWindow.all(app).firstIndex { $0.nsWindow === nsWindow } ?? -1) + 1
        }
        set { if newValue == 1 { nsWindow?.orderFront(nil) } }
    }
    @objc var hasCloseBox: Bool { nsWindow?.styleMask.contains(.closable) ?? false }
    @objc var isMiniaturizable: Bool { nsWindow?.styleMask.contains(.miniaturizable) ?? false }
    @objc var isMiniaturized: Bool {
        get { nsWindow?.isMiniaturized ?? false }
        set { newValue ? nsWindow?.miniaturize(nil) : nsWindow?.deminiaturize(nil) }
    }
    @objc var isResizable: Bool { nsWindow?.styleMask.contains(.resizable) ?? false }
    @objc var isVisible: Bool {
        get { nsWindow?.isVisible ?? false }
        set { newValue ? nsWindow?.orderFront(nil) : nsWindow?.orderOut(nil) }
    }
    @objc var isZoomable: Bool { nsWindow?.styleMask.contains(.resizable) ?? false }
    @objc var isZoomed: Bool {
        get { nsWindow?.isZoomed ?? false }
        set { if newValue != (nsWindow?.isZoomed ?? false) { nsWindow?.zoom(nil) } }
    }
    /// Arc's `incognito` and `mode`: set only when making a window (ScriptMakeCommand reads them from the record).
    @objc var isIncognito: Bool {
        get { privateWindow != nil }
        set {}
    }
    @objc var mode: String {
        get { privateWindow != nil ? "incognito" : "normal" }
        set {}
    }

    @objc var activeTab: ScriptTab? {
        if let p = privateWindow { return p.shownID.map { ScriptTab(.privatePage($0), in: self) } }
        guard let c = browser, let id = c.shownTabID, let t = c.store.tab(id) else { return nil }
        return ScriptTab(t.itemID.map(ScriptTab.Ref.item) ?? .today(t.id), in: self)
    }

    @objc var activeSpace: ScriptSpace? {
        guard let c = browser, c.store.space(c.currentSpaceID) != nil else { return nil }
        return ScriptSpace(c.currentSpaceID, in: self)
    }

    // MARK: Elements

    /// The spaces this window shows: the listed ones, or a blank window's own.
    @objc var scriptSpaces: [ScriptSpace] {
        guard let c = browser else { return [] }
        return c.windowSpaces.map { ScriptSpace($0.id, in: self) }
    }

    @objc(valueInScriptSpacesWithUniqueID:)
    func valueInScriptSpaces(withUniqueID id: String) -> ScriptSpace? { scriptSpaces.first { $0.spaceID == id } }

    /// Every space's tabs in order, each once (a profile's Favorites belong to all its spaces); a private window's own.
    @objc var scriptTabs: [ScriptTab] {
        if let p = privateWindow { return p.pages.map { ScriptTab(.privatePage($0.id), in: self) } }
        guard let c = browser else { return [] }
        var seen = Set<ScriptTab.Ref>()
        return c.windowSpaces.flatMap { ScriptTab.refs(ofSpace: $0.id, in: c.store) }.filter { seen.insert($0).inserted }
            .map { ScriptTab($0, in: self) }
    }

    @objc(valueInScriptTabsWithUniqueID:)
    func valueInScriptTabs(withUniqueID id: String) -> ScriptTab? { scriptTabs.first { $0.uniqueID == id } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil, key: "aircScriptWindows",
                                   uniqueID: uniqueID)
    }
}

@objc(AircScriptSpace)
final class ScriptSpace: NSObject {
    let spaceID: String
    let window: ScriptWindow

    init(_ spaceID: String, in window: ScriptWindow) {
        self.spaceID = spaceID
        self.window = window
    }

    @objc var uniqueID: String { spaceID }
    @objc var title: String { window.store?.space(spaceID)?.name ?? "" }
    @objc var profileName: String {
        guard let store = window.store, store.space(spaceID) != nil else { return "" }
        return store.profile(ofSpace: spaceID).name
    }

    @objc var scriptTabs: [ScriptTab] {
        guard let store = window.store else { return [] }
        return ScriptTab.refs(ofSpace: spaceID, in: store).map { ScriptTab($0, in: window) }
    }

    @objc(valueInScriptTabsWithUniqueID:)
    func valueInScriptTabs(withUniqueID id: String) -> ScriptTab? { scriptTabs.first { $0.uniqueID == id } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = window.objectSpecifier, let desc = NSScriptClassDescription(for: ScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: desc, containerSpecifier: container, key: "scriptSpaces",
                                   uniqueID: spaceID)
    }
}

@objc(AircScriptTab)
final class ScriptTab: NSObject {
    enum Ref: Hashable {
        /// A Favorite or pinned tab (a pinned split's pane too), by its item.
        case item(String)
        /// A Today tab.
        case today(String)
        /// A private window's page.
        case privatePage(String)
    }

    let ref: Ref
    let window: ScriptWindow

    init(_ ref: Ref, in window: ScriptWindow) {
        self.ref = ref
        self.window = window
    }

    /// A space's tabs as its sidebar has them: its profile's Favorites, its pinned tree (every folder, open or not,
    /// and each pinned split's panes), then Today.
    static func refs(ofSpace spaceID: String, in store: SpacesStore) -> [Ref] {
        guard let space = store.space(spaceID) else { return [] }
        func tabs(of item: Item) -> [Ref] {
            switch item.kind {
            case .tab: return [.item(item.id)]
            case .split: return store.panes(ofSplitItem: item.id).map { .item($0.id) }
            case .folder: return store.children(of: item.container, parent: item.id).flatMap(tabs)
            }
        }
        return store.favorites(ofProfile: space.profileID).flatMap(tabs)
            + store.children(of: .pinned(spaceID: spaceID), parent: nil).flatMap(tabs)
            + store.todayTabs(ofSpace: spaceID).map { .today($0.id) }
    }

    var store: SpacesStore? { window.store }
    var item: Item? { if case .item(let id) = ref { return store?.item(id) }; return nil }

    /// The store's tab for this row (an unloaded pinned tab or Favorite has none until it opens).
    var liveTab: LiveTab? {
        switch ref {
        case .item(let id): return store?.liveTab(forItem: id)
        case .today(let id): return store?.tab(id)
        case .privatePage: return nil
        }
    }

    /// The loaded page, in whichever window has it.
    var page: EngineTab? {
        if case .privatePage(let id) = ref { return window.privateController?.page(id)?.tab }
        guard let t = liveTab, let app = NSApp.delegate as? AppDelegate else { return nil }
        return app.controllers.lazy.compactMap { $0.engineTab(for: t.id) }.first
    }

    var isPrivate: Bool { if case .privatePage = ref { return true }; return false }

    var exists: Bool {
        switch ref {
        case .item(let id): return store?.item(id) != nil
        case .today(let id): return store?.tab(id) != nil
        case .privatePage(let id): return window.privateController?.page(id) != nil
        }
    }

    // MARK: Properties (Arc's names in Airc.sdef)

    @objc var uniqueID: String {
        switch ref {
        case .item(let id), .today(let id), .privatePage(let id): return id
        }
    }

    @objc var title: String {
        if let p = page, !p.title.isEmpty { return p.title }
        return item?.displayTitle ?? liveTab?.displayTitle ?? ""
    }

    /// Setting it loads the address in the tab (opening it first if it isn't loaded).
    @objc var URL: String {
        get { page?.url?.absoluteString ?? liveTab?.url ?? item?.savedURL ?? "" }
        set {
            guard let url = ScriptTab.url(newValue) else { return }
            if page == nil { ScriptingActions.show(self) }
            guard let page else { return }
            // As ⌘L loads in place: the store first, then the engine window (which may hand it to another engine).
            if let t = liveTab, let app = NSApp.delegate as? AppDelegate, let c = app.pageOwner(of: t.id) ?? window.controller {
                c.store.updateTab(t.id, url: url.absoluteString)
                c.engineWindow.load(url, in: page)
            } else {
                page.load(url)
            }
        }
    }

    @objc var loading: Bool { page?.isLoading ?? false }

    @objc var location: String {
        switch ref {
        case .item: return item?.isFavorite == true ? "topApp" : "pinned"
        case .today, .privatePage: return "unpinned"
        }
    }

    /// An address a script gave: absolute with a scheme, else nil.
    static func url(_ text: String) -> Foundation.URL? {
        guard let u = Foundation.URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.isEmpty == false else { return nil }
        return u
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container = window.objectSpecifier, let desc = NSScriptClassDescription(for: ScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: desc, containerSpecifier: container, key: "scriptTabs",
                                   uniqueID: uniqueID)
    }
}

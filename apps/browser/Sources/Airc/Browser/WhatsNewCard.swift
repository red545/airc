// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// "What's new" after an update (owner request, 2026-11-13: "a card like this of what was included"): on the first
/// launch of a new version, the update pill's spot above the sidebar's footer shows "Airc 0.1.13 is here", up to five
/// one-line highlights with their symbols (the versions since the one this data folder ran last, newest first, merged,
/// "And more" past five), See All (the changelog at this version, in a new tab) and ×. It stays for three launches or
/// until dismissed, and is never offered twice for a version, nor on a fresh install (onboarding has that launch).
///
/// The lines come from the app's bundled WhatsNew.json, written once per release by scripts/release/whatsnew.py from
/// the notes; the rules are AircKit's WhatsNew.swift (unit-tested), the drawing is UpdateButtonView's.
///
/// whatsnew2: Settings › General › Automatic Updates › "After an update" chooses Open a What's new tab (the default:
/// the "What's New in Airc" tab, Browser/WhatsNewPage.swift, opens once in the front window and no card shows), Show a
/// small card (this card, whose body and See All open that tab) or Don't show (the "Updated!" toast, as before).
final class WhatsNewCenter {
    static let shared = WhatsNewCenter()
    static let changed = Notification.Name("AircWhatsNewChanged")

    /// What the card shows now, else nil.
    private(set) var content: WhatsNewContent?
    #if AIRC_TESTING
    /// Checks hand it their own file (nil: the bundle's).
    var catalogOverride: WhatsNewCatalog?
    /// What See All opened last (the checks read it).
    private(set) var openedForCheck: URL?
    #endif

    /// "Airc 0.1.13 is here".
    static func title(_ c: WhatsNewContent) -> String { "Airc \(c.version) is here" }
    /// Longest first: the card's header takes the first that fits the sidebar.
    static func titles(_ c: WhatsNewContent) -> [String] { [title(c), "Airc \(c.version)"] }

    static var stateFile: URL { AppPaths.dataDirectory.appendingPathComponent("WhatsNewState.json") }

    /// The bundled file (Contents/Resources/WhatsNew.json); nil if it's missing or invalid (no card then).
    var catalog: WhatsNewCatalog? {
        #if AIRC_TESTING
        if let catalogOverride { return catalogOverride }
        #endif
        return Self.bundled
    }

    static let bundled: WhatsNewCatalog? = {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? WhatsNewCatalog.decode(data)
    }()

    var state: WhatsNewState {
        get { (try? Data(contentsOf: Self.stateFile)).flatMap { try? JSONDecoder().decode(WhatsNewState.self, from: $0) } ?? WhatsNewState() }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            try? data.write(to: Self.stateFile, options: .atomic)
        }
    }

    /// Settings › General › Automatic Updates › After an update.
    var style: WhatsNewStyle { (NSApp.delegate as? AppDelegate)?.settings?.values.whatsNewStyle ?? .tab }
    /// Anything after updates (the tab or the card, and the Restart to Update card's lines).
    var isEnabled: Bool { style != .off }

    /// At launch (UpdateCenter.noteLaunchedVersion), with the version the data folder ran last (nil on a fresh install)
    /// and the running one. true when the card shows this launch.
    @discardableResult
    func noteLaunch(previous: String?, current: String) -> Bool {
        var s = state
        let range = s.launch(previous: previous, current: current, enabled: isEnabled)
        state = s
        guard let range, let catalog, let c = WhatsNewContent.merge(catalog, from: range.from, current: range.current) else {
            set(nil)
            return false
        }
        if style == .tab {
            // The tab, once: it ends the card for this version (the tab stays until it's closed or archived).
            UpdateCenter.shared.log("what's new: \(c.versions.joined(separator: ", ")) since \(range.from), the What's new tab")
            s.dismiss()
            state = s
            set(nil)
            openTabWhenReady(from: range.from, to: range.current, tries: 20)
            return true
        }
        UpdateCenter.shared.log("what's new: \(c.versions.joined(separator: ", ")) since \(range.from), launch \(s.shownLaunches) of \(WhatsNewState.launches)")
        set(c)
        return true
    }

    // MARK: The What's new tab (whatsnew2)

    /// What the tab at `url` lists: its range, else the running version's own release.
    func pageContent(_ url: String?) -> WhatsNewPageContent? {
        guard let catalog else { return nil }
        if let r = WhatsNewURL.range(url) { return WhatsNewPageContent.make(catalog, from: r.from, current: r.to) }
        return WhatsNewPageContent.latest(catalog, current: UpdateCenter.runningVersion)
    }

    /// Opens (or brings back) the What's new tab in `controller`'s current Space, listing `from`…`to`.
    @discardableResult
    func openTab(from: String?, to: String, in controller: WindowController? = nil) -> String? {
        guard let w = controller ?? (NSApp.delegate as? AppDelegate)?.controller else { return nil }
        let url = from.map { WhatsNewURL.make(from: $0, to: to) } ?? WhatsNewURL.prefix
        let store = w.store
        let id: String
        if let open = store.state.tabs.values.first(where: { $0.spaceID == w.currentSpaceID && WhatsNewURL.isPage($0.url) }) {
            id = open.id
            if open.url != url { store.updateTab(id, url: url, title: WhatsNewURL.title) }
        } else {
            guard let t = try? store.openTab(url: url, inSpace: w.currentSpaceID, title: WhatsNewURL.title) else { return nil }
            id = t.id
        }
        if let page = WhatsNewPage.existing(id) { page.model.content = pageContent(url) }
        UpdateCenter.shared.log("what's new: tab \(url)")
        #if AIRC_TESTING
        openedTabForCheck = id
        #endif
        w.show(id)
        return id
    }

    #if AIRC_TESTING
    /// The tab openTab opened last (the checks read it).
    private(set) var openedTabForCheck: String?
    #endif

    /// At launch the first window may not be on screen yet: the tab opens once it is.
    private func openTabWhenReady(from: String, to: String, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let c = (NSApp.delegate as? AppDelegate)?.controller, c.window.isVisible, c.hasLaidOutCard else {
                if tries > 0 { self?.openTabWhenReady(from: from, to: to, tries: tries - 1) }
                return
            }
            self?.openTab(from: from, to: to, in: c)
        }
    }

    /// × on the card: gone for good for this version.
    func dismiss() {
        guard content != nil else { return }
        var s = state
        s.dismiss()
        state = s
        UpdateCenter.shared.log("what's new: dismissed")
        set(nil)
    }

    /// See All, or a click on the card: the What's new tab for the card's versions (whatsnew2; the tab links the full
    /// changelog). The card stays (× closes it).
    func seeAll(from controller: WindowController?) {
        guard let c = content, let w = controller ?? (NSApp.delegate as? AppDelegate)?.controller else { return }
        UpdateCenter.shared.log("what's new: see all → the What's new tab")
        #if AIRC_TESTING
        openedForCheck = URL(string: WhatsNewURL.make(from: state.from ?? c.version, to: c.version))
        #endif
        openTab(from: state.from, to: c.version, in: w)
    }

    /// The setting changed: off (or the tab) takes the card away now (it counts as dismissed); the next update has
    /// whichever is chosen.
    func settingChanged(_ style: WhatsNewStyle) {
        if style != .card { dismiss() }
        NotificationCenter.default.post(name: Self.changed, object: self)   // the update pill's lines follow it
    }

    private func set(_ c: WhatsNewContent?) {
        guard c != content else { return }
        content = c
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    #if AIRC_TESTING
    /// Checks: show (or hide) a card without touching the state file.
    func showForCheck(_ c: WhatsNewContent?) { set(c) }
    #endif
}

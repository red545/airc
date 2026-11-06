// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Downloads, the media tray and the call window for the main window: one per app, because the engine takes one
/// observer per profile and per tab (engine/PASS13.md). The window's hooks below are all it needs from WindowController.
final class MediaLibrary {
    static let shared = MediaLibrary()

    weak var controller: WindowController?
    private(set) var downloads: DownloadCenter?
    private(set) var media: MediaCenter?
    private(set) lazy var calls = CallWindowController(library: self)
    private var prompts: DownloadPrompts?
    private var appObservers: [NSObjectProtocol] = []
    private var windowWatchers: [NSKeyValueObservation] = []

    /// The main window is up (WindowController.init): listen to every profile as it loads.
    func attach(_ c: WindowController) {
        controller = c
        guard let engine = c.app?.engine else { return }
        if downloads == nil, let d = engine as? EngineDownloads, d.downloadsAvailable {
            let center = DownloadCenter(engine: d)
            center.library = self
            downloads = center
            d.downloadsCloseConfirmation = { [weak self] count, answer in
                guard let self, let p = self.prompts else { return answer(true) }
                p.askBeforeClosing(count: count, answer)
            }
        }
        if media == nil, let m = engine as? EngineMedia, m.mediaAvailable {
            let center = MediaCenter(engine: m)
            center.library = self
            media = center
        }
        prompts = DownloadPrompts(controller: c, library: self)
        calls.chainPictureInPicture()
        PiPOverlays.shared.attach(self)
        c.sidebar.tray.connect(self, controller: c)
        let previous = c.profiles.didLoad
        c.profiles.didLoad = { [weak self, weak c] p in
            previous?(p)
            guard let self, let c else { return }
            self.profileLoaded(p, in: c)
        }
        for p in c.profiles.loadedProfiles { profileLoaded(p, in: c) }
        // The call window follows the main window leaving the screen, not Airc resigning active (Notification Center and
        // Spotlight take the focus with the page still in view).
        appObservers.forEach(NotificationCenter.default.removeObserver)
        let changed: (Notification) -> Void = { [weak self] _ in self?.calls.mainWindowVisibilityChanged() }
        appObservers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            .map { NotificationCenter.default.addObserver(forName: $0, object: c.window, queue: .main, using: changed) }
            + [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            .map { NotificationCenter.default.addObserver(forName: $0, object: NSApp, queue: .main, using: changed) }
        // Ordered out or in (no notification of its own).
        windowWatchers = [c.window.observe(\.isVisible) { [weak self] _, _ in
            DispatchQueue.main.async { self?.calls.mainWindowVisibilityChanged() }
        }]
    }

    private func profileLoaded(_ p: EngineProfile, in c: WindowController) {
        guard let id = c.profiles.profileID(for: p) else { return }
        downloads?.attach(p, profileID: id)
        media?.attach(p, profileID: id)
    }

    /// Downloads or players came or went: the tray's height follows.
    func trayContentChanged() {
        controller?.sidebar.tray.contentChanged()
    }

    /// A risky download is being asked about, or no longer.
    func downloadPromptChanged() {
        prompts?.refresh()
    }

    /// The card on screen (the scripted checks click it).
    var promptView: DownloadBubbleView? { prompts?.view }

    /// The window was laid out: the card stays above the tray.
    func layoutPrompts() { prompts?.layout() }

    #if AIRC_TESTING
    /// The checks: the downloads card (its "still running" form, laid out like the risky-file one) without a download.
    func showDownloadCardForTesting(count: Int) { prompts?.askBeforeClosing(count: count) { _ in } }
    #endif

    /// The Library opens on Downloads (a click on the sidebar's download row).
    func showDownloads() {
        controller?.showLibrary(.downloads)
    }

    var dangerPrompt: DownloadCenter.Item? { downloads?.dangerous }
}

// MARK: - The window's hooks

extension WindowController {
    /// WindowController.init.
    func setUpMediaLibrary() {
        MediaLibrary.shared.attach(self)
    }

    /// The end of refreshChrome(): what's on screen (the tray leaves it out; a call leaving the screen opens its call
    /// window) and the theme.
    func mediaLibraryChromeChanged() {
        let lib = MediaLibrary.shared
        guard lib.controller === self else { return }
        sidebar.tray.setTheme(currentPalette.resolved)
        let now = visibleTabIDs
        lib.media?.visibilityChanged(now)
        lib.calls.visibleTabsChanged(now)
    }

    /// The start of show(): a page in the call window comes back to its tab first.
    func bringBackFromCallWindow(_ tabID: String) {
        let lib = MediaLibrary.shared
        guard lib.controller === self, lib.calls.holds(tabID) else { return }
        lib.calls.returnPage(showing: true)
    }

    /// windowDidBecomeKey: a call that went to its window while this window was off screen comes back.
    func mediaLibraryWindowBecameKey() {
        guard MediaLibrary.shared.controller === self else { return }
        MediaLibrary.shared.calls.mainWindowBecameKey()
    }

    /// windowShouldClose: an engine that doesn't ask about running downloads itself (WebKit) asks here first. True: the
    /// close waits for the answer.
    func downloadsHoldClose() -> Bool {
        MediaLibrary.shared.downloadsHoldClose(window)
    }

    /// Opens the Library on `section` (or switches it there).
    func showLibrary(_ section: LibraryModel.Section) {
        if library == nil { toggleLibrary() }
        library?.model.section = section
    }

    /// After a page came back from the call window without being shown: the card shows what it showed (the returned
    /// page is hidden again).
    func reshowCurrentPage() {
        if let id = shownTabID { show(id, focus: false, updatesRows: false) } else { engineWindow.deactivateAll() }
    }
}

extension MediaLibrary {
    private static var closeConfirmed = false

    func downloadsHoldClose(_ window: NSWindow) -> Bool {
        guard let d = downloads, !d.engine.asksBeforeClosingWithDownloads, d.runningCount > 0, let p = prompts else { return false }
        if Self.closeConfirmed { return false }
        p.askBeforeClosing(count: d.runningCount) { [weak window] close in
            guard close, let window else { return }
            Self.closeConfirmed = true
            window.performClose(nil)
            DispatchQueue.main.async { Self.closeConfirmed = false }
        }
        return true
    }
}

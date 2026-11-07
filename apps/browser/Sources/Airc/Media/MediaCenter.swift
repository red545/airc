// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import Combine

/// The media tray's sessions (SB-54): every tab, in any Space, that plays media or is in a call, from the engine's
/// Media Session tabs and per-tab observers (engine/PASS13.md). Nothing polls (MEM-6): a change comes from the engine,
/// or from the window when the tabs on screen change. One per app (MediaLibrary).
final class MediaCenter: ObservableObject {
    struct Player: Identifiable, Equatable {
        let tabID: String
        var session: EngineMediaSession
        /// The track's title, else the page's.
        var title: String
        /// The artist, else the site.
        var subtitle: String
        var pageURL: String
        var muted: Bool
        /// When it last started playing (the tray shows the latest first; calls come before music).
        var since: Date
        var id: String { tabID }
        var isCall: Bool { session.isCall }
    }

    /// What the tray shows: the sessions of tabs that aren't on screen.
    @Published private(set) var players: [Player] = []
    /// Every tab with a session, on screen or not, by tab ID.
    private(set) var sessions: [String: Player] = [:]

    let engine: EngineMedia
    weak var library: MediaLibrary?
    private var profileTabs: [String: [EngineTab]] = [:]   // profile ID → its media tabs
    private var watched: [ObjectIdentifier: EngineTab] = [:]
    private var observedProfiles: [String: EngineProfile] = [:]
    private var visible: Set<String> = []

    init(engine: EngineMedia) {
        self.engine = engine
    }

    // MARK: Engine

    func attach(_ profile: EngineProfile, profileID: String) {
        guard observedProfiles[profileID] == nil else { return }
        observedProfiles[profileID] = profile
        engine.observeMediaTabs(in: profile) { [weak self] tabs in
            // PASS13: a callback mustn't change the engine's structures synchronously.
            DispatchQueue.main.async { self?.mediaTabsChanged(profileID, tabs) }
        }
    }

    func detachAll() {
        for p in observedProfiles.values { engine.observeMediaTabs(in: p, nil) }
        for t in watched.values { engine.observeMediaSession(of: t, nil) }
        observedProfiles = [:]
        watched = [:]
    }

    private func mediaTabsChanged(_ profileID: String, _ tabs: [EngineTab]) {
        let live = tabs.filter { !$0.isClosed }
        profileTabs[profileID] = live
        let all = profileTabs.values.flatMap { $0 }
        let keep = Set(all.map(ObjectIdentifier.init))
        for (key, tab) in watched where !keep.contains(key) {
            engine.observeMediaSession(of: tab, nil)
            watched[key] = nil
            if let id = library?.tabID(for: tab) { sessionEnded(id) }
        }
        for tab in all where watched[ObjectIdentifier(tab)] == nil {
            watched[ObjectIdentifier(tab)] = tab
            engine.observeMediaSession(of: tab) { [weak self, weak tab] s in
                guard let tab else { return }
                self?.sessionChanged(tab, s)
            }
        }
        refresh()
    }

    private func sessionChanged(_ tab: EngineTab, _ s: EngineMediaSession) {
        PiPOverlays.shared.sessionChanged(tab, s)
        guard let id = library?.tabID(for: tab) else { return }
        guard s.isPresent, !tab.isClosed else { return sessionEnded(id) }
        let old = sessions[id]
        var p = old ?? Player(tabID: id, session: s, title: "", subtitle: "", pageURL: "", muted: tab.isMuted, since: Date())
        if old == nil || (s.playback == .playing && old?.session.playback != .playing) { p.since = Date() }
        p.session = s
        describe(&p, tab: tab)
        sessions[id] = p
        library?.calls.sessionChanged(id, s)
        refresh()
    }

    private func sessionEnded(_ id: String) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        library?.calls.sessionChanged(id, EngineMediaSession())
        refresh()
    }

    private func describe(_ p: inout Player, tab: EngineTab) {
        let s = p.session
        let url = tab.url?.absoluteString ?? ""
        let host = URLRules.displayHost(url)
        p.pageURL = url
        p.muted = tab.isMuted
        p.title = !s.title.isEmpty ? s.title : (!tab.title.isEmpty ? tab.title : host)
        if s.isCall {
            // The buttons show the microphone and camera; the line says only what's off, and sharing.
            var parts: [String] = []
            if s.capture.screen || s.capture.tab { parts.append("Sharing") }
            if (s.actions.contains("togglemicrophone") || s.microphoneActive != nil) && !s.microphoneOn { parts.append("Muted") }
            if (s.actions.contains("togglecamera") || s.cameraActive != nil) && !s.cameraOn { parts.append("Camera off") }
            p.subtitle = parts.isEmpty ? host : parts.joined(separator: " · ")
        } else {
            p.subtitle = !s.artist.isEmpty ? s.artist : host
        }
    }

    /// The tabs on screen changed (WindowController.refreshChrome): the tray leaves out what you're looking at.
    func visibilityChanged(_ now: Set<String>) {
        guard now != visible else { return }
        visible = now
        refresh()
    }

    /// The page's title, mute or the window changed: the rows say so.
    func pageChanged(_ tabID: String) {
        if let page = library?.page(for: tabID) { PiPOverlays.shared.pageChanged(page) }
        guard var p = sessions[tabID], let page = library?.page(for: tabID) else { return }
        describe(&p, tab: page)
        guard p != sessions[tabID] else { return }
        sessions[tabID] = p
        refresh()
    }

    private func refresh() {
        let shown = sessions.values.filter { !visible.contains($0.tabID) && library?.controller?.store.tab($0.tabID) != nil }
            .sorted { a, b in a.isCall != b.isCall ? a.isCall : a.since > b.since }
        if shown != players {
            players = shown
            library?.trayContentChanged()
        }
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: String, _ p: Player) -> Bool {
        guard let page = library?.page(for: p.tabID), p.session.actions.contains(action)
            || (["play", "pause"].contains(action) && p.session.playback != .none) else { return false }
        return engine.performMediaAction(action, value: 0, in: page)
    }

    func togglePlayback(_ p: Player) {
        perform(p.session.playback == .playing ? "pause" : "play", p)
    }

    /// The tab's sound (playback only: a call's microphone is `togglemicrophone`).
    func toggleMute(_ p: Player) {
        guard let page = library?.page(for: p.tabID) else { return }
        page.isMuted.toggle()
        pageChanged(p.tabID)
    }

    /// A click on the player: its tab, in its Space.
    func goToTab(_ p: Player) {
        guard let c = library?.controller, let tab = c.store.tab(p.tabID) else { return }
        if let sid = tab.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
        c.show(p.tabID)
    }
}

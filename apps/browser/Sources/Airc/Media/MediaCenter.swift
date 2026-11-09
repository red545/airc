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
        /// A Safari-engine page's video is in the system picture in picture window.
        var inSystemPictureInPicture = false
        /// When it last started playing (the tray shows the latest first; calls come before music).
        var since: Date
        var positionUpdatedAt = Date()
        var playbackPosition: Double {
            let elapsed = session.playback == .playing ? Date().timeIntervalSince(positionUpdatedAt) * session.rate : 0
            return min(session.duration ?? .infinity, max(0, (session.position ?? 0) + elapsed))
        }
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
    // Unloading removes the window's page mapping before the engine ends its session.
    // Retain the identity for the observer's lifetime so teardown can still clear Now Playing.
    private var watchedTabIDs: [ObjectIdentifier: String] = [:]
    private var observedProfiles: [String: EngineProfile] = [:]
    private var visible: Set<String> = []
    private var trackStates: [ObjectIdentifier: (Bool?, Bool?)] = [:]
    var retainedTrackCount: Int { trackStates.count }
    lazy var nowPlaying = MediaNowPlaying(center: self)
    private var rawSessions: [ObjectIdentifier: EngineMediaSession] = [:]
    /// Players closed from the tray (Arc's Close Mini Player): out of it until their tab plays again or is shown.
    private var closed: Set<String> = []

    func trackStateChanged(_ tab: EngineTab, json: String) {
        guard !tab.isClosed else { return }
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        let key = ObjectIdentifier(tab)
        let mic = d["mic"] as? Bool, cam = d["cam"] as? Bool
        // The script announces null/null on every page. Keep only pages with outgoing tracks; preserve an early
        // track report arriving before the engine adds this call to its watched media tabs.
        guard mic != nil || cam != nil || trackStates[key] != nil else { return }
        trackStates[key] = (mic, cam)
        sessionChanged(tab, rawSessions[key] ?? engine.mediaSession(of: tab))
    }

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
        watchedTabIDs = [:]
        profileTabs = [:]
        trackStates = [:]
        rawSessions = [:]
        sessions = [:]
        closed = []
        players = []
        nowPlaying.update()
    }

    private func mediaTabsChanged(_ profileID: String, _ tabs: [EngineTab]) {
        let live = tabs.filter { !$0.isClosed }
        profileTabs[profileID] = live
        let all = profileTabs.values.flatMap { $0 }
        let keep = Set(all.map(ObjectIdentifier.init))
        for (key, tab) in watched where !keep.contains(key) {
            engine.observeMediaSession(of: tab, nil)
            watched[key] = nil
            trackStates[key] = nil
            rawSessions[key] = nil
            if let id = watchedTabIDs.removeValue(forKey: key) ?? library?.tabID(for: tab) { sessionEnded(id) }
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

    private func sessionChanged(_ tab: EngineTab, _ raw: EngineMediaSession) {
        let key = ObjectIdentifier(tab)
        rawSessions[key] = raw
        var s = raw
        if let (mic, cam) = trackStates[key] {
            s.microphoneActive = mic ?? s.microphoneActive
            s.cameraActive = cam ?? s.cameraActive
        }
        PiPOverlays.shared.sessionChanged(tab, s)
        guard let id = library?.tabID(for: tab) ?? watchedTabIDs[key] else { return }
        if watched[key] != nil { watchedTabIDs[key] = id }
        guard s.isPresent, !tab.isClosed else { return sessionEnded(id) }
        let old = sessions[id]
        var p = old ?? Player(tabID: id, session: s, title: "", subtitle: "", pageURL: "", muted: tab.isMuted, since: Date())
        if old == nil || (s.playback == .playing && old?.session.playback != .playing) {
            p.since = Date()
            closed.remove(id)
        }
        p.session = s
        p.positionUpdatedAt = Date()
        describe(&p, tab: tab)
        sessions[id] = p
        library?.calls.sessionChanged(id, s)
        refresh()
    }

    private func sessionEnded(_ id: String) {
        closed.remove(id)
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
        p.inSystemPictureInPicture = (tab as? WebKitTab).map(SystemPictureInPicture.isOpen) ?? false
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
        for id in now.subtracting(visible) {
            closed.remove(id)
            if let page = library?.page(for: id), HiddenMiniPlayers.isHidden(page) {
                // Returning to the tab ends this hidden presentation; the next playback can open normally.
                PiPOverlays.shared.close(page, pause: false)
                HiddenMiniPlayers.forget(page)
            }
        }
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

    func miniPlayerVisibilityChanged() { refresh() }

    private func refresh() {
        nowPlaying.update()
        let shown = sessions.values.filter { p in
            let hidden = library?.page(for: p.tabID).map { HiddenMiniPlayers.isHidden($0) } ?? false
            return (!visible.contains(p.tabID) || hidden) && !closed.contains(p.tabID) && library?.controller?.store.tab(p.tabID) != nil
        }
            .sorted { a, b in a.isCall != b.isCall ? a.isCall : a.since > b.since }
        if shown != players {
            players = shown
            library?.trayContentChanged()
        }
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: String, _ p: Player, value: Double = 0) -> Bool {
        guard let page = library?.page(for: p.tabID), p.session.actions.contains(action)
            || (["play", "pause"].contains(action) && p.session.playback != .none) else { return false }
        return engine.performMediaAction(action, value: value, in: page)
    }

    func togglePlayback(_ p: Player) {
        perform(p.session.playback == .playing ? "pause" : "play", p)
    }

    /// Close Player (Arc's Close Mini Player): the media pauses, its picture in picture closes, and the row goes until
    /// the tab plays again or you go back to it. Not for calls: their row is where the microphone shows.
    func closePlayer(_ p: Player) {
        guard !p.isCall, let page = library?.page(for: p.tabID) else { return }
        if p.session.playback == .playing { perform("pause", p) }
        if let webKit = page as? WebKitTab, SystemPictureInPicture.isOpen(webKit) { webKit.closeSystemPictureInPicture(pause: true) }
        if PiPOverlays.shared.controls(for: page)?.window != nil || HiddenMiniPlayers.isHidden(page) {
            PiPOverlays.shared.close(page, pause: true)
        }
        closed.insert(p.tabID)
        refresh()
    }

    /// The tab's sound (playback only: a call's microphone is `togglemicrophone`).
    func toggleMute(_ p: Player) {
        guard let page = library?.page(for: p.tabID) else { return }
        page.isMuted.toggle()
        pageChanged(p.tabID)
    }

    /// A click on a hidden player's tray row brings back the same window without interrupting playback.
    func activatePlayer(_ p: Player) {
        if let page = library?.page(for: p.tabID), HiddenMiniPlayers.show(page) { return }
        goToTab(p)
    }

    /// Back to Tab: its tab, in its Space.
    func goToTab(_ p: Player) {
        guard let c = library?.controller, let tab = c.store.tab(p.tabID) else { return }
        if let sid = tab.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
        c.show(p.tabID)
    }
}

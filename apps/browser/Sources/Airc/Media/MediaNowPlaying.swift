// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import MediaPlayer

/// One command destination for both engines. Pausing retains the last-playing tab so Play resumes it.
/// Chromium's independent hardware-key listener is disabled at startup; page Media Sessions stay enabled.
final class MediaNowPlaying {
    weak var center: MediaCenter?
    private var tokens: [(MPRemoteCommand, Any)] = []
    private(set) var tabID: String?
    private var artworkURL: String?
    private var artworkTabID: String?
    private var artworkGeneration = UUID()
    private var artwork: MPMediaItemArtwork?

    init(center: MediaCenter) {
        self.center = center
        let c = MPRemoteCommandCenter.shared()
        for (command, action) in [(c.playCommand, "play"), (c.pauseCommand, "pause"),
            (c.togglePlayPauseCommand, "toggle"), (c.nextTrackCommand, "nexttrack"), (c.previousTrackCommand, "previoustrack"),
            (c.changePlaybackPositionCommand, "seekto")] {
            let token = command.addTarget { [weak self] event in
                let value = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
                let run = { self?.perform(action, value: value) == true ? MPRemoteCommandHandlerStatus.success : .noSuchContent }
                if Thread.isMainThread { return run() }
                // Accept delivery without blocking MediaPlayer's callback queue on AppKit.
                // Main may itself be inside a MediaPlayer call; synchronous dispatch can form a cycle.
                DispatchQueue.main.async { _ = run() }
                return .success
            }
            tokens.append((command, token))
        }
    }

    deinit { tokens.forEach { $0.0.removeTarget($0.1) } }

    @discardableResult func perform(_ action: String, value: Double = 0) -> Bool {
        guard let center, let id = tabID, let p = center.sessions[id] else { return false }
        return center.perform(action == "toggle" ? (p.session.playback == .playing ? "pause" : "play") : action, p, value: value)
    }

    func update() {
        let p = center?.sessions.values.filter { !$0.isCall }.max { $0.since < $1.since }
        tabID = p?.tabID
        let c = MPRemoteCommandCenter.shared(), info = MPNowPlayingInfoCenter.default()
        c.playCommand.isEnabled = p != nil
        c.pauseCommand.isEnabled = p != nil
        c.togglePlayPauseCommand.isEnabled = p != nil
        c.nextTrackCommand.isEnabled = p?.session.actions.contains("nexttrack") == true
        c.previousTrackCommand.isEnabled = p?.session.actions.contains("previoustrack") == true
        c.changePlaybackPositionCommand.isEnabled = p?.session.actions.contains("seekto") == true
        guard let p else { info.nowPlayingInfo = nil; info.playbackState = .stopped; artworkURL = nil; artworkTabID = nil; artworkGeneration = UUID(); artwork = nil; return }
        let s = p.session
        // Only a live ordinary store tab may use the shared network/disk cache. Unknown/private
        // sessions fail closed, even if a future caller starts registering them with this center.
        let ordinary = center?.library?.controller?.store.tab(p.tabID) != nil
            && center?.library?.page(for: p.tabID) != nil
        let source = MediaArtworkPolicy.source(s.artwork, ordinaryTab: ordinary)
        if artworkURL != source || artworkTabID != p.tabID {
            artworkURL = source; artworkTabID = p.tabID; artwork = nil
            artworkGeneration = UUID()
            let generation = artworkGeneration
            if let url = artworkURL {
                let receive: (NSImage?) -> Void = { [weak self] image in
                    guard let self, self.artworkGeneration == generation, self.artworkURL == url, let image else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.update()
                }
                if url.hasPrefix("data:") { receive(TrayArtwork.decodeDataURL(url)) }
                else if url.hasPrefix("https://") || url.hasPrefix("http://") { FaviconCache.shared.load(url, completion: receive) }
            }
        }
        var values: [String: Any] = [MPMediaItemPropertyTitle: p.title, MPMediaItemPropertyArtist: p.subtitle,
            MPMediaItemPropertyAlbumTitle: s.album, MPNowPlayingInfoPropertyPlaybackRate: s.playback == .playing ? s.rate : 0]
        if let d = s.duration { values[MPMediaItemPropertyPlaybackDuration] = d }
        if s.position != nil { values[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.playbackPosition }
        if let artwork { values[MPMediaItemPropertyArtwork] = artwork }
        info.nowPlayingInfo = values
        info.playbackState = s.playback == .playing ? .playing : .paused
    }
}

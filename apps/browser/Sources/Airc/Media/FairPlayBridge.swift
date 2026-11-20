// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// Adapted from Ardia's FairPlay bridge (https://github.com/ardia-browser/ardia): packages/ardiacore/ios/ArdiaFairPlay.mm
// (the browser side: one owner, generations, playlist parts, size limits, "stolen") and packages/ardiacore/fairplay/
// main.swift (the player: AVURLAsset from a custom-scheme playlist, AVContentKeySession, licence timeout, position
// reports), both Copyright 2026 Mantra Patel, licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0); modified by The Airc Authors: one in-process player instead of a helper
// app, Airc's page-script parts and media tray instead of Ardia's tab registry and the helper's own Now Playing.

import AVFoundation
import AppKit
import AircKit
import Combine

/// The FairPlay bridge (docs/design/fairplay-bridge.md): plays the HLS playlist a listed site's player gives its media
/// element with a native AVPlayer, keys through AVContentKeySession, the licence exchanged by the page's own code.
/// Exists only while Settings › Privacy › "Play protected media in Chromium with FairPlay" is on.
final class FairPlayBridge: NSObject {
    static let shared = FairPlayBridge()
    static let part = "fairplay"
    static let failed = Notification.Name("AircFairPlayBridgeFailed")
    private static let playlistScheme = "airc-fairplay"
    private static let licenseTimeout: TimeInterval = 30

    // MARK: Setting and sites

    /// The setting (test builds: AIRC_FAIRPLAY_BRIDGE=0|1 forces it).
    static var isEnabled: Bool {
        #if AIRC_TESTING
        if let forced = forcedForTest { return forced }
        if let v = ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_BRIDGE"] { return v != "0" }
        #endif
        return (NSApp.delegate as? AppDelegate)?.settings?.values.fairPlayInChromium ?? false
    }

    /// The exact origins the bridge serves (FairPlayBridgeSites; a test adds its loopback page's).
    static var origins: [String] {
        #if AIRC_TESTING
        if let t = testOrigin { return FairPlayBridgeSites.origins + [t] }
        #endif
        return FairPlayBridgeSites.origins
    }

    /// Every origin the bridge keeps in Chromium (audio and video; the routing exception in ProtectedMedia).
    static var routedOrigins: [String] { FairPlayBridgeSites.withAliases(origins + FairPlayVideo.origins) }

    #if AIRC_TESTING
    /// `--script fairplayvideo`: a loopback page's origin that plays a listed video site (any path is a player page).
    static var testVideoOrigin: String? = ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_TEST_VIDEO_ORIGIN"] {
        didSet { shared.settingChanged() }
    }
    /// `--script fairplayua`: a loopback origin that gets Safari's user agent like Netflix.
    static var testUserAgentOrigin: String? = ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_TEST_UA_ORIGIN"] {
        didSet { shared.settingChanged() }
    }
    /// `--script fairplayua`: an alias of the test's Netflix origin (as netflix.com is of www.netflix.com).
    static var testUserAgentAlias: String?
    /// `--script fairplaybridge`: the setting, forced (nil: the setting).
    static var forcedForTest: Bool? { didSet { shared.settingChanged() } }
    /// A loopback page's origin that plays a listed site, where a clear playlist (no FairPlay key) also plays.
    static var testOrigin: String? = ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_TEST_ORIGIN"] {
        didSet { shared.settingChanged() }
    }
    #endif

    private static var clearTestOrigin: String? {
        #if AIRC_TESTING
        return testOrigin
        #else
        return nil
        #endif
    }

    /// The bridge serves this page message: the top frame, a listed origin as the engine committed it, the setting on,
    /// a Chromium page.
    static func serves(_ tab: EngineTab, _ m: EnginePageMessage) -> Bool {
        isEnabled && m.isMainFrame && !(tab is WebKitTab) && FairPlayBridgeSites.serves(origin: m.origin, in: origins)
    }

    // MARK: Install

    private var installed = false
    private var partSet = false
    private var settingsWatch: AnyCancellable?

    /// Once, before the first page (Chromium builds only): the part follows the setting from now on.
    static func install() {
        let s = shared
        guard !s.installed else { return }
        s.installed = true
        s.settingsWatch = (NSApp.delegate as? AppDelegate)?.settings?.$values.map(\.fairPlayInChromium).removeDuplicates()
            .dropFirst().sink { _ in DispatchQueue.main.async { s.settingChanged() } }
        s.settingChanged()
    }

    private func settingChanged() {
        guard installed, let scripts = PageScripts.shared else { return }
        if Self.isEnabled {
            let source = FairPlayBridgeScript.source(origins: Self.origins, clearTestOrigin: Self.clearTestOrigin)
            scripts.set(Self.part, source: source) { [weak self] tab, m in self?.received(tab, m) }
            partSet = true
            FairPlayVideo.shared.settingChanged(enabled: true)
        } else if partSet {
            partSet = false
            // Pages already open keep the part: they're told it's off (their element pauses), and the player goes.
            if let owner = ownerTab {
                deliver(["event": "stolen", "gen": generation])
                _ = PageScripts.shared?.callDocument(owner, frame: ownerFrame, origin: ownerOrigin, part: Self.part,
                                                     kind: "enabled", json: "false")
            }
            stop()
            scripts.remove(Self.part)
            FairPlayVideo.shared.settingChanged(enabled: false)
        }
    }

    // MARK: State

    private weak var ownerTab: EngineTab?
    private var ownerFrame = ""
    private var ownerOrigin = ""
    /// The page's generation for the current load (its `gen`).
    private var generation = 0
    private var failedGeneration = 0
    private var playedGeneration = 0
    // Playlist parts being collected.
    private weak var partsTab: EngineTab?
    private var partsFrame = ""
    private var partsGeneration = 0
    private var parts: [String] = []
    private var partsCertificate = ""

    private var player: AVPlayer?
    private var track: Track?
    private var ticker: Timer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var lastPosition: (time: Double, playing: Bool, sequence: Int)?
    private var completedSeek = 0
    private var pageMuted = false
    private var tabMuted = false
    private var volume: Float = 1

    // What the tray shows.
    private var title = "", artist = "", album = "", artwork = ""
    private var actions: [String] = []
    private var reported: EngineMediaSession?
    /// The media tray (MediaCenter registers itself).
    weak var center: MediaCenter?

    /// Whether `tab` is the page the bridge plays for.
    func owns(_ tab: EngineTab) -> Bool { (ownerTab === tab && track != nil) || FairPlayVideo.shared.owns(tab) }

    /// The tray's session for the page the bridge plays for (nil for any other page).
    func session(for tab: EngineTab) -> EngineMediaSession? {
        guard ownerTab === tab, let track, let player else { return FairPlayVideo.shared.session(for: tab) }
        var s = EngineMediaSession()
        s.playback = player.timeControlStatus == .paused ? .paused : .playing
        s.active = true
        s.title = title
        s.artist = artist
        s.album = album
        s.artwork = artwork.isEmpty ? [] : [artwork]
        let d = CMTimeGetSeconds(track.item.duration)
        s.duration = d.isFinite && d > 0 ? d : nil
        let t = CMTimeGetSeconds(player.currentTime())
        s.position = t.isFinite ? max(0, t) : 0
        s.rate = 1
        s.actions = Set(actions).union(["seekto"])
        return s
    }

    /// The tray's buttons and the media keys (MediaCenter.perform): the page's own handlers, else the element.
    func perform(_ action: String, value: Double, in tab: EngineTab) -> Bool {
        guard ownerTab === tab, track != nil else { return FairPlayVideo.shared.perform(action, value: value, in: tab) }
        var event: [String: Any] = ["event": "remote", "command": action]
        if action == "seekto" { event["time"] = value }
        deliver(event)
        return true
    }

    // MARK: Messages from the page

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        guard Self.serves(tab, m) else { return }
        let d = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        if m.kind == "load" { return loadPart(tab, m, d) }
        if m.kind == "offered" { return }
        // Site Controls offers Safari's engine on a page whose Widevine the bridge refused (as on any Widevine page).
        if m.kind == "widevine" { return ProtectedMedia.noteWidevineAsked(tab, origin: m.origin) }
        guard ownerTab === tab, m.frame == ownerFrame, m.origin == ownerOrigin else { return }
        switch m.kind {
        case "license":
            guard let gen = Self.whole(d["gen"]), gen == generation, let ckc = Self.text(d["ckc"], FairPlayBridgeSites.maxLicenseText),
                  let data = Data(base64Encoded: ckc), !data.isEmpty else { return }
            track?.license(data)
        case "play": player?.play()
        case "pause": player?.pause()
        case "seek":
            guard let time = Self.number(d["time"]), time >= 0, let seq = Self.whole(d["seq"]) else { return }
            seek(to: time, sequence: seq)
        case "volume":
            guard let v = Self.number(d["volume"]) else { return }
            volume = Float(min(max(v, 0), 1))
            player?.volume = volume
        case "muted":
            pageMuted = d["muted"] as? Bool ?? false
            applyMuted()
        case "metadata":
            title = Self.text(d["title"], 1024) ?? ""
            artist = Self.text(d["artist"], 1024) ?? ""
            album = Self.text(d["album"], 1024) ?? ""
            let art = Self.text(d["artwork"], 4096) ?? ""
            artwork = URL(string: art)?.scheme == "https" ? art : ""
            report()
        case "actions":
            actions = ((d["actions"] as? [Any]) ?? []).compactMap { Self.text($0, 32) }.prefix(16).map { $0 }
            report()
        case "failed":
            if let gen = Self.whole(d["gen"]), gen == generation { failed("player") }
        case "stop": stop()
        default: break
        }
    }

    private func loadPart(_ tab: EngineTab, _ m: EnginePageMessage, _ d: [String: Any]) {
        guard let gen = Self.whole(d["gen"]), gen >= 1, let total = Self.whole(d["parts"]), (1...FairPlayBridgeSites.maxParts).contains(total),
              let part = Self.whole(d["part"]), (0..<total).contains(part),
              let text = Self.text(d["playlist"], FairPlayBridgeSites.maxPlaylistPart) else { return }
        if part == 0 {
            partsTab = tab
            partsFrame = m.frame
            partsGeneration = gen
            parts = []
            partsCertificate = Self.text(d["cert"], FairPlayBridgeSites.maxCertificateText) ?? ""
            if let v = Self.number(d["volume"]) { volume = Float(min(max(v, 0), 1)) }
            pageMuted = d["muted"] as? Bool ?? false
        }
        guard partsTab === tab, partsFrame == m.frame, partsGeneration == gen, parts.count == part else { return }
        parts.append(text)
        guard parts.count == total else { return }
        let playlist = parts.joined()
        let certificate = Data(base64Encoded: partsCertificate) ?? Data()
        parts = []
        partsCertificate = ""
        partsTab = nil

        // A new owner: the previous page's element pauses.
        if ownerTab !== tab || ownerFrame != m.frame || ownerOrigin != m.origin {
            if ownerTab != nil { deliver(["event": "stolen", "gen": generation]) }
            stop()
            playedGeneration = 0
            failedGeneration = 0
        }
        ownerTab = tab
        ownerFrame = m.frame
        ownerOrigin = m.origin
        generation = gen

        let clear = Self.clearTestOrigin == m.origin && FairPlayBridgeSites.keyURI(in: playlist) == nil
        // A test page's clear segments come from its own loopback server, by name or by address (AVFoundation's
        // loads outside web content follow App Transport Security, which leaves loopback addresses alone).
        let testOrigins = Self.clearTestOrigin == m.origin
            ? [m.origin, m.origin.replacingOccurrences(of: "://localhost:", with: "://127.0.0.1:")] : []
        guard FairPlayBridgeSites.isRemotePlaylist(playlist, allowing: testOrigins),
              clear || (!certificate.isEmpty && FairPlayBridgeSites.keyURI(in: playlist) != nil)
        else { return failed("playback") }
        startPlayer(playlist: Data(playlist.utf8), certificate: certificate)
    }

    // MARK: The player

    private func startPlayer(playlist: Data, certificate: Data) {
        tearDownTrack()
        let player = self.player ?? {
            let p = AVPlayer()
            p.automaticallyWaitsToMinimizeStalling = true
            self.player = p
            return p
        }()
        let gen = generation
        let t = Track(generation: gen, certificate: certificate, playlist: playlist, scheme: Self.playlistScheme,
                      licenseTimeout: Self.licenseTimeout)
        t.onRequest = { [weak self] spc in self?.deliver(["event": "request", "gen": gen, "spc": spc.base64EncodedString()]) }
        t.onFailure = { [weak self] step in
            guard let self, self.track === t else { return }
            self.player?.pause()
            self.failed(step)
        }
        track = t
        completedSeek = 0
        lastPosition = nil
        player.volume = volume
        applyMuted()
        player.replaceCurrentItem(with: t.item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: t.item, queue: .main) { [weak self] _ in
            guard let self, self.track === t else { return }
            self.deliver(["event": "ended", "gen": gen])
            self.report()
        }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: t.item, queue: .main) { [weak self] _ in
            guard let self, self.track === t else { return }
            t.fail("playback")
        }
        if ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        report()
    }

    private func applyMuted() {
        var muted = pageMuted || tabMuted
        #if AIRC_TESTING
        // Scripted checks never make sound (the person may be at the Mac).
        if ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_AUDIBLE"] != "1" { muted = true }
        #endif
        player?.isMuted = muted
    }

    private func seek(to time: Double, sequence: Int) {
        guard let track, let player else { return }
        if track.item.status != .readyToPlay {
            track.pendingSeek = (time, sequence)
            return
        }
        seek(track, player, to: time, sequence: sequence)
    }

    private func seek(_ track: Track, _ player: AVPlayer, to time: Double, sequence: Int) {
        let duration = CMTimeGetSeconds(track.item.duration)
        let target = duration.isFinite && duration > 0 ? min(time, duration) : time
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.track === track else { return }
                self.completedSeek = max(self.completedSeek, sequence)
                self.tick()
            }
        }
    }

    private func tick() {
        guard let track, let player, let owner = ownerTab else { return stop() }
        if owner.isClosed { return stop() }
        if owner.isMuted != tabMuted {
            tabMuted = owner.isMuted
            applyMuted()
        }
        if track.item.status == .failed { return track.fail("playback") }
        if !track.announcedReady && track.item.status == .readyToPlay {
            let duration = CMTimeGetSeconds(track.item.duration)
            if duration.isFinite && duration > 0 {
                track.announcedReady = true
                deliver(["event": "ready", "gen": generation, "duration": duration])
            }
        }
        if track.item.status == .readyToPlay, let pending = track.pendingSeek {
            track.pendingSeek = nil
            seek(track, player, to: pending.time, sequence: pending.sequence)
        }
        let seconds = CMTimeGetSeconds(player.currentTime())
        let time = seconds.isFinite ? seconds : 0
        let playing = player.timeControlStatus == .playing
        if playing && playedGeneration != generation { playedGeneration = generation }
        report()
        if !playing, let last = lastPosition, !last.playing, last.sequence == completedSeek, abs(last.time - time) < 0.05 { return }
        lastPosition = (time, playing, completedSeek)
        deliver(["event": "position", "gen": generation, "time": time, "playing": playing, "seq": completedSeek])
    }

    /// The tray learns of a change (play state, metadata, a seek).
    private func report() {
        guard let owner = ownerTab else { return }
        let s = session(for: owner)
        guard s?.playback != reported?.playback || s?.title != reported?.title || s?.artist != reported?.artist
                || s?.artwork != reported?.artwork || s?.actions != reported?.actions || s?.duration != reported?.duration
                || abs((s?.position ?? 0) - (reported?.position ?? 0)) > 1.5 else { return }
        reported = s
        center?.bridgeSessionChanged(owner)
    }

    private func failed(_ step: String) {
        guard failedGeneration != generation else { return }
        failedGeneration = generation
        let known = ["license", "playback", "player"].contains(step) ? step : "playback"
        deliver(["event": "failed", "gen": generation, "step": known])
        let owner = ownerTab
        tearDownTrack()
        if let owner {
            center?.bridgeSessionChanged(owner)
            NotificationCenter.default.post(name: Self.failed, object: owner, userInfo: ["step": known])
        }
    }

    /// An event for the owning document only (callDocument: nothing reaches a document that navigated away).
    private func deliver(_ event: [String: Any]) {
        guard let owner = ownerTab, let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let sent = PageScripts.shared?.callDocument(owner, frame: ownerFrame, origin: ownerOrigin, part: Self.part,
                                                    kind: "event", json: json) ?? false
        if !sent, track != nil { DispatchQueue.main.async { [weak self] in self?.stop() } }
    }

    private func tearDownTrack() {
        track?.cancel()
        track = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        for o in [endObserver, failObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        failObserver = nil
        lastPosition = nil
        reported = nil
    }

    /// The page stopped, closed or went away, or the setting went off: nothing is left playing.
    func stop() {
        let owner = ownerTab
        tearDownTrack()
        player = nil
        ticker?.invalidate()
        ticker = nil
        ownerTab = nil
        ownerFrame = ""
        ownerOrigin = ""
        generation = 0
        parts = []
        partsTab = nil
        partsCertificate = ""
        title = ""; artist = ""; album = ""; artwork = ""
        actions = []
        if let owner { center?.bridgeSessionChanged(owner) }
    }

    // MARK: Input

    /// A JSON number (never a JSON true/false: an NSNumber of 0 or 1 also says `is Bool`, so ask CoreFoundation).
    static func jsonNumber(_ v: Any?) -> NSNumber? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private static func whole(_ v: Any?) -> Int? {
        guard let n = jsonNumber(v) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), d >= 0, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = jsonNumber(v), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func text(_ v: Any?, _ max: Int) -> String? {
        guard let s = v as? String, s.utf8.count <= max else { return nil }
        return s
    }

    #if AIRC_TESTING
    /// For the check: whether a native player exists, and its state.
    var testState: [String: Any] {
        guard let player, let track else { return ["player": false] }
        return ["player": true, "ready": track.announcedReady, "rate": player.rate,
                "time": CMTimeGetSeconds(player.currentTime()), "muted": player.isMuted, "volume": player.volume,
                "licensed": track.licensed, "requested": track.requested, "origin": ownerOrigin,
                "itemStatus": track.item.status.rawValue, "itemError": track.item.error.map { "\($0)" } ?? ""]
    }
    #endif
}

/// One playlist: its asset (read through a custom scheme, so the playlist never touches disk or the network), the item,
/// and its FairPlay key session.
private final class Track: NSObject, AVContentKeySessionDelegate, AVAssetResourceLoaderDelegate {
    let generation: Int
    let certificate: Data
    let playlist: Data
    let scheme: String
    let licenseTimeout: TimeInterval
    let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    let asset: AVURLAsset
    lazy var item = AVPlayerItem(asset: asset)
    var pendingSeek: (time: Double, sequence: Int)?
    var announcedReady = false
    var onRequest: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var requested = false
    private(set) var licensed = false
    private var exchanging = false
    private var cancelled = false
    private var announcedFailure = false
    private var awaitingLicense: AVContentKeyRequest?
    private var licenseDeadline: Timer?
    private let loaderQueue: DispatchQueue

    init(generation: Int, certificate: Data, playlist: Data, scheme: String, licenseTimeout: TimeInterval) {
        self.generation = generation
        self.certificate = certificate
        self.playlist = playlist
        self.scheme = scheme
        self.licenseTimeout = licenseTimeout
        loaderQueue = DispatchQueue(label: "airc.fairplay.playlist.\(generation)")
        asset = AVURLAsset(url: URL(string: "\(scheme)://track/\(generation).m3u8")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        session.setDelegate(self, queue: .main)
        session.addContentKeyRecipient(asset)
    }

    func resourceLoader(_ loader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == scheme else { return false }
        request.contentInformationRequest?.contentType = "public.m3u-playlist"
        request.contentInformationRequest?.contentLength = Int64(playlist.count)
        request.contentInformationRequest?.isByteRangeAccessSupported = false
        request.dataRequest?.respond(with: playlist)
        request.finishLoading()
        return true
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide request: AVContentKeyRequest) { requestLicense(request) }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest request: AVContentKeyRequest) {
        requestLicense(request)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest request: AVContentKeyRequest, didFailWithError error: Error) {
        fail("license")
    }

    private func requestLicense(_ request: AVContentKeyRequest) {
        if exchanging || cancelled { return }
        guard !certificate.isEmpty else { return fail("license") }
        exchanging = true
        let identifier = (request.identifier as? String) ?? ""
        let contentIdentifier = Data(identifier.replacingOccurrences(of: "skd://", with: "").utf8)
        request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentIdentifier, options: nil) { spc, _ in
            DispatchQueue.main.async {
                guard !self.cancelled else { return }
                guard let spc else {
                    self.exchanging = false
                    return self.fail("license")
                }
                self.awaitingLicense = request
                self.requested = true
                self.licenseDeadline?.invalidate()
                self.licenseDeadline = Timer.scheduledTimer(withTimeInterval: self.licenseTimeout, repeats: false) { [weak self] _ in
                    if self?.awaitingLicense != nil { self?.fail("license") }
                }
                self.onRequest?(spc)
            }
        }
    }

    func license(_ ckc: Data) {
        guard let request = awaitingLicense, !cancelled else { return }
        awaitingLicense = nil
        exchanging = false
        licensed = true
        licenseDeadline?.invalidate()
        request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
    }

    func fail(_ step: String) {
        if cancelled || announcedFailure { return }
        announcedFailure = true
        let handler = onFailure
        cancel()
        handler?(step)
    }

    func cancel() {
        cancelled = true
        licenseDeadline?.invalidate()
        awaitingLicense = nil
        onRequest = nil
        onFailure = nil
        session.expire()
    }
}

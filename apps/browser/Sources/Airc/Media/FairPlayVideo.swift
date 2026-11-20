// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// Adapted from Ardia's protected-video player (https://github.com/ardia-browser/ardia, packages/ardiacore/ios:
// ArdiaProtectedVideo.mm, ArdiaPVSession.mm, ArdiaPVSession+Playback.mm, ArdiaPVSession+Keys.mm,
// ArdiaPVSession+PictureInPicture.mm, ArdiaProtectedVideoMedia.mm), which is Copyright 2026 Mantra Patel, licensed
// under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0); modified by The Airc Authors:
// Swift, Airc's page-script parts and media tray, one layer view placed over Airc's page view, a smaller picture in
// picture, no controls copy yet.

import AVFoundation
import AVKit
import AppKit
import AircKit
import CoreMedia
#if canImport(AircCore)
import AircCore
#endif

/// The FairPlay video bridge (docs/design/fairplay-bridge.md, step 2): a listed video site's MediaSource appends and EME
/// calls come from the `fairplayvideo` part; this plays them with AVSampleBufferDisplayLayer and
/// AVSampleBufferAudioRenderer under one synchronizer, keys from an AVContentKeySession whose recipients are the
/// renderers, and draws the layer over the page's video rectangle.
final class FairPlayVideo {
    static let shared = FairPlayVideo()
    static let part = "fairplayvideo"

    /// The exact origins the video bridge serves (a test adds its loopback page's). Netflix only with an engine that
    /// gives it Safari's user agent.
    static var origins: [String] {
        var list = FairPlayBridgeSites.videoOrigins.filter { !FairPlayBridgeSites.safariUserAgentOrigins.contains($0) || engineUserAgents }
        #if AIRC_TESTING
        if let t = FairPlayBridge.testVideoOrigin { list.append(t) }
        if let t = FairPlayBridge.testUserAgentOrigin { list.append(t) }
        #endif
        return list
    }

    /// Safari's user agent, as WebKit pages send it (this Mac's Safari version).
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + WebKitProfile.safariProduct

    private static let setUserAgentSelector = NSSelectorFromString("setUserAgent:forOrigin:")

    /// The engine can give one origin its own user agent (engine/core airc_user_agent_overrides).
    static var engineUserAgents: Bool {
        #if canImport(AircCore)
        return AircProfile.instancesRespond(to: setUserAgentSelector)
        #else
        return false
        #endif
    }

    /// The origins that get Safari's user agent while the setting is on: https://www.netflix.com and, as the one
    /// deliberate addition to "exact origin only" (lead, 2026-11-20), its bare domain https://netflix.com, the same
    /// service, which redirects to www (a navigation keeps the user agent it started with). Nothing else.
    static var userAgentOrigins: [String] {
        var list = FairPlayBridgeSites.withAliases(FairPlayBridgeSites.safariUserAgentOrigins)
        #if AIRC_TESTING
        if let t = FairPlayBridge.testUserAgentOrigin { list.append(t) }
        if let t = FairPlayBridge.testUserAgentAlias { list.append(t) }
        #endif
        return list
    }

    private var userAgentsOn = false

    #if AIRC_TESTING
    /// What applyUserAgents did (`--script fairplayua`).
    static var appliedUserAgents: [String] = []
    #endif

    /// Gives (or takes back) Safari's user agent on its origins in every Chromium profile.
    private func applyUserAgents(_ on: Bool) {
        #if canImport(AircCore)
        guard Self.engineUserAgents, let engine = (NSApp.delegate as? AppDelegate)?.engine as? ChromiumEngine else { return }
        userAgentsOn = on
        for p in engine.profiles.values { apply(on, to: p.core) }
        #endif
    }

    #if canImport(AircCore)
    private func apply(_ on: Bool, to core: AircProfile) {
        #if AIRC_TESTING
        Self.appliedUserAgents.append("\(on ? "on" : "off") \(URL(fileURLWithPath: core.path).lastPathComponent) \(Self.userAgentOrigins)")
        #endif
        for o in Self.userAgentOrigins {
            _ = core.perform(Self.setUserAgentSelector, with: on ? Self.safariUserAgent : nil, with: o)
        }
    }

    /// A profile loaded after the setting went on (MediaCenter.attach).
    func profileLoaded(_ profile: EngineProfile) {
        guard userAgentsOn, let p = profile as? ChromiumProfile else { return }
        apply(true, to: p.core)
    }
    #endif

    private var sessions: [ObjectIdentifier: FairPlayVideoSession] = [:]
    private var partSet = false

    /// The setting changed (FairPlayBridge): the part comes or goes; open players stop when it's off.
    func settingChanged(enabled: Bool) {
        guard let scripts = PageScripts.shared else { return }
        if enabled {
            #if AIRC_TESTING
            let anyPath = FairPlayBridge.testVideoOrigin
            #else
            let anyPath: String? = nil
            #endif
            scripts.set(Self.part, source: FairPlayVideoScript.source(origins: Self.origins, anyPathOrigin: anyPath,
                                                                      userAgent: Self.safariUserAgent)) { [weak self] tab, m in
                self?.received(tab, m)
            }
            partSet = true
            applyUserAgents(true)
        } else if partSet {
            partSet = false
            for s in sessions.values { s.failAt("player", reason: "setting off"); s.close() }
            sessions = [:]
            scripts.remove(Self.part)
            applyUserAgents(false)
        }
    }

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        guard FairPlayBridge.isEnabled, m.isMainFrame, !(tab is WebKitTab),
              FairPlayBridgeSites.serves(origin: m.origin, in: Self.origins) else { return }
        let d = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        if m.kind == "offered" { return }
        if m.kind == "asked" { return FairPlayBridge.shared.noteAskedFromVideo(d) }
        if m.kind == "widevine" { return FairPlayBridge.shared.widevineRefused(tab, origin: m.origin) }
        if m.kind == "attach" { FairPlayBridge.shared.bridgeStarted(tab) }
        sessions = sessions.filter { $0.value.tab != nil && $0.value.tab?.isClosed == false }
        let key = ObjectIdentifier(tab)
        var session = sessions[key]
        if let s = session, s.frame != m.frame || s.origin != m.origin {
            s.close()
            session = nil
        }
        if session == nil {
            let s = FairPlayVideoSession(tab: tab, frame: m.frame, origin: m.origin)
            s.onChange = { [weak self, weak tab] in
                guard let tab else { return }
                self?.changed(tab)
            }
            sessions[key] = s
            session = s
        }
        session?.handle(m.kind, d)
    }

    private func changed(_ tab: EngineTab) { FairPlayBridge.shared.center?.bridgeSessionChanged(tab) }

    /// The page's player is gone (closed tab, navigation): its session closes.
    func pageGone(_ tab: EngineTab) {
        sessions.removeValue(forKey: ObjectIdentifier(tab))?.close()
    }

    func owns(_ tab: EngineTab) -> Bool { sessions[ObjectIdentifier(tab)]?.isActive == true }

    func session(for tab: EngineTab) -> EngineMediaSession? { sessions[ObjectIdentifier(tab)]?.trayState() }

    func perform(_ action: String, value: Double, in tab: EngineTab) -> Bool {
        guard let s = sessions[ObjectIdentifier(tab)], s.isActive else { return false }
        s.remote(action, value)
        return true
    }

    #if AIRC_TESTING
    func testState(_ tab: EngineTab) -> [String: Any] { sessions[ObjectIdentifier(tab)]?.testState ?? ["session": false] }
    func testSession(_ tab: EngineTab) -> FairPlayVideoSession? { sessions[ObjectIdentifier(tab)] }
    #endif
}

// MARK: - Stored media

private let kMaxPartChars = 62 * 1024
private let kMaxParts = 800
private let kMaxUnitBytes = 32 * 1024 * 1024
private let kMaxKeyData = 48 * 1024
private let kMaxBuffers = 8
private let kMaxKeySessions = 64
private let kMaxStoredSegments = 4000
private let kMaxStoredBytes = 320 * 1024 * 1024
private let kJoin = 0.3
private let kOverlap = 0.05
private let kUpcomingWindow = 16
private let kKeepBehind = 30.0
private let kResumeAhead = 1.0
private let kTick = 0.25
private let kContentKeyTimedOut = -19152

private func startOf(_ s: CMSampleBuffer) -> Double { CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(s)) }
private func endOf(_ s: CMSampleBuffer) -> Double {
    let d = CMSampleBufferGetDuration(s)
    return startOf(s) + (d.isNumeric ? CMTimeGetSeconds(d) : 0)
}
private func isSync(_ s: CMSampleBuffer) -> Bool {
    guard let a = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false), CFArrayGetCount(a) > 0 else { return true }
    let first = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFDictionary.self)
    guard let v = CFDictionaryGetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) else { return true }
    return !CFBooleanGetValue(unsafeBitCast(v, to: CFBoolean.self))
}
/// One sample per buffer, shifted by `offset` seconds (timestampOffset).
private func singleSamples(_ buffer: CMSampleBuffer, offset: Double) -> [CMSampleBuffer] {
    var out: [CMSampleBuffer] = []
    let count = CMSampleBufferGetNumSamples(buffer)
    for i in 0..<count {
        var one: CMSampleBuffer?
        if count == 1 { one = buffer }
        else if CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleRange: CFRange(location: i, length: 1), sampleBufferOut: &one) != noErr { continue }
        guard var sample = one else { continue }
        if offset != 0 {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { continue }
            let scale = timing.presentationTimeStamp.isValid ? timing.presentationTimeStamp.timescale : 90000
            let delta = CMTime(seconds: offset, preferredTimescale: max(scale, 1000))
            if timing.presentationTimeStamp.isValid { timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, delta) }
            if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, delta) }
            var shifted: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted)
            guard let s = shifted else { continue }
            sample = s
        }
        out.append(sample)
    }
    return out
}
/// A copy the renderer decodes but doesn't show (frames before a seek target, from its key frame on).
private func hiddenCopy(_ s: CMSampleBuffer) -> CMSampleBuffer? {
    var copy: CMSampleBuffer?
    guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: s, sampleBufferOut: &copy) == noErr, let c = copy else { return nil }
    if let a = CMSampleBufferGetSampleAttachmentsArray(c, createIfNecessary: true) {
        for i in 0..<CFArrayGetCount(a) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(a, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
    return c
}

final class FairPlayVideoSegment {
    var samples: [CMSampleBuffer]
    var start: Double
    var end: Double
    var bytes: Int
    var kid: Data?
    var serial: Int
    init(samples: [CMSampleBuffer], start: Double, end: Double, bytes: Int, kid: Data?, serial: Int) {
        self.samples = samples; self.start = start; self.end = end; self.bytes = bytes; self.kid = kid; self.serial = serial
    }
}

/// One SourceBuffer: its fMP4 parser (AVFoundation's AVStreamDataParser, as WebKit's MSE uses) and the unit being
/// assembled from the page's parts.
final class FairPlayVideoTrack: NSObject {
    let buffer: Int
    var video = false
    private var parser: NSObject?
    var initData: Data?
    var kid: Data?
    var timescale: UInt32 = 0
    var parsedVideo: [CMSampleBuffer] = []
    var parsedAudio: [CMSampleBuffer] = []
    var parseError: String?
    var assemblySeq = -1
    var assemblyNext = 0
    var assembly: Data?
    /// Key request init data the parser found (`{"sinf": [...]}`), not yet announced to the page.
    var pendingKeyData: [Data] = []

    init(buffer: Int) {
        self.buffer = buffer
        super.init()
        parser = (NSClassFromString("AVStreamDataParser") as? NSObject.Type)?.init()
        _ = parser?.perform(NSSelectorFromString("setDelegate:"), with: self)
    }

    deinit { _ = parser?.perform(NSSelectorFromString("setDelegate:"), with: nil) }

    func parse(_ unit: Data) -> Bool {
        parsedVideo = []
        parsedAudio = []
        guard let parser else { parseError = "no stream parser"; return false }
        parseError = nil
        _ = parser.perform(NSSelectorFromString("appendStreamData:"), with: unit as NSData)
        _ = parser.perform(NSSelectorFromString("providePendingMediaData"))
        return parseError == nil
    }

    @objc(streamDataParser:didParseStreamDataAsAsset:) func parsedAsset(_ parser: AnyObject, asset: AVAsset) {}
    @objc(streamDataParser:didParseStreamDataAsAsset:withDiscontinuity:) func parsedAsset(_ parser: AnyObject, asset: AVAsset, discontinuity: Bool) {}
    @objc(streamDataParser:didFailToParseStreamDataWithError:) func failed(_ parser: AnyObject, error: NSError) {
        parseError = error.localizedDescription
    }
    @objc(streamDataParser:didProvideMediaData:forTrackID:mediaType:flags:)
    func provided(_ parser: AnyObject, sample: CMSampleBuffer, trackID: CMPersistentTrackID, mediaType: NSString, flags: UInt) {
        if mediaType as String == AVMediaType.video.rawValue { parsedVideo.append(sample) }
        else if mediaType as String == AVMediaType.audio.rawValue { parsedAudio.append(sample) }
    }
    @objc(streamDataParserWillProvideContentKeyRequestInitializationData:forTrackID:)
    func willProvideKeyData(_ parser: AnyObject, trackID: CMPersistentTrackID) {}
    @objc(streamDataParser:didProvideContentKeyRequestInitializationData:forTrackID:)
    func providedKeyData(_ parser: AnyObject, data: NSData, trackID: CMPersistentTrackID) {
        if kid == nil, let k = FairPlayMP4.sinfKeyIDs(data as Data).first { kid = k }
        pendingKeyData.append(data as Data)
    }
}

/// The segments stored for one renderer, and where it's being fed from.
final class FairPlayVideoLane {
    let video: Bool
    let renderer: AVQueuedSampleBufferRendering
    var stored: [FairPlayVideoSegment] = []
    var feed: FairPlayVideoSegment?
    var feedIndex = 0
    var from = 0.0
    var requesting = false
    var dirty = false
    var blocked = false
    var enqueued = Set<ObjectIdentifier>()
    var format: CMFormatDescription?
    var promisedFloor = CMTime.invalid

    init(renderer: AVQueuedSampleBufferRendering, video: Bool) { self.renderer = renderer; self.video = video }

    func containing(_ time: Double) -> FairPlayVideoSegment? {
        var best: FairPlayVideoSegment?
        for s in stored where s.start <= time + kOverlap && s.end > time && (best == nil || s.serial > best!.serial) { best = s }
        if let best { return best }
        for s in stored where s.start > time && s.start < time + kJoin && (best == nil || s.start < best!.start) { best = s }
        return best
    }

    func following(_ tail: FairPlayVideoSegment) -> FairPlayVideoSegment? {
        var best: FairPlayVideoSegment?
        for s in stored where s !== tail && s.start > tail.start && abs(s.start - tail.end) < kJoin && (best == nil || s.serial > best!.serial) { best = s }
        return best
    }

    func endFrom(_ time: Double) -> Double {
        guard var s = containing(time) else { return .nan }
        for _ in 0..<stored.count {
            guard let next = following(s) else { break }
            s = next
        }
        return s.end
    }

    var bytes: Int { stored.reduce(0) { $0 + $1.bytes } }

    private func drop(_ remove: (FairPlayVideoSegment) -> Bool, position: Double) {
        for old in stored where remove(old) {
            if old === feed { feed = nil; dirty = true }
            else if enqueued.contains(ObjectIdentifier(old)) && old.end > position { dirty = true }
        }
        stored.removeAll(where: remove)
    }

    func store(_ segment: FairPlayVideoSegment, position: Double) {
        drop({ segment.start < $0.end - kOverlap && segment.end > $0.start + kOverlap }, position: position)
        let at = stored.firstIndex { $0.start > segment.start } ?? stored.count
        stored.insert(segment, at: at)
        if stored.count > kMaxStoredSegments {
            let excess = Set(stored.prefix(stored.count - kMaxStoredSegments).map(ObjectIdentifier.init))
            drop({ excess.contains(ObjectIdentifier($0)) }, position: position)
        }
    }

    func remove(from start: Double, to end: Double, position: Double) {
        drop({ let m = ($0.start + $0.end) / 2; return m >= start && m < end }, position: position)
    }

    func evict(before time: Double, position: Double) {
        drop({ $0.end < time && $0 !== self.feed }, position: position)
    }

    /// Feeds from the key frame at or before `time`.
    func cue(at time: Double) {
        feed = nil
        feedIndex = 0
        guard let segment = containing(time) else { return }
        feed = segment
        guard video, let at = stored.firstIndex(where: { $0 === segment }) else { return }
        var i = at
        while i >= 0 && i + 4 > at {
            let candidate = stored[i]
            var found = -1
            for (k, s) in candidate.samples.enumerated() where isSync(s) && startOf(s) <= time + 1e-4 { found = k }
            if found >= 0 { feed = candidate; feedIndex = found; return }
            if i > 0 && abs(candidate.start - stored[i - 1].end) >= kJoin { return }
            i -= 1
        }
    }

    /// The lowest presentation time over the next frames (for B-frames; as WebKit does).
    func upcomingFloor() -> CMTime {
        var floor = CMTime.invalid
        var segment = feed
        var index = feedIndex, seen = 0
        while let s = segment, seen < kUpcomingWindow {
            if index >= s.samples.count { segment = following(s); index = 0; continue }
            let t = CMSampleBufferGetPresentationTimeStamp(s.samples[index]); index += 1
            if !t.isNumeric { return .invalid }
            if !floor.isNumeric || CMTimeCompare(t, floor) < 0 { floor = t }
            seen += 1
        }
        return seen == kUpcomingWindow ? floor : .invalid
    }

    func clear() {
        renderer.stopRequestingMediaData()
        requesting = false
        stored = []
        enqueued = []
        feed = nil
        feedIndex = 0
        dirty = false
        blocked = false
        from = 0
        promisedFloor = .invalid
        format = nil
    }
}

private final class FairPlayVideoKeySession {
    var keySystem = ""
    var raw = true
    var succeeded = false
    var awaitingKid: Data?
    var rawQueue: [(kid: Data, spc: Data)] = []
}

/// The view that holds the video layer over the page: clicks go through to the page.
private final class FairPlayVideoLayerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

// MARK: - The session

final class FairPlayVideoSession: NSObject, AVContentKeySessionDelegate, AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate {
    weak var tab: EngineTab?
    let frame: String
    let origin: String
    var onChange: (() -> Void)?

    private let keyQueue = DispatchQueue(label: "airc.fairplay.video.keys")
    private let keys = AVContentKeySession(keySystem: .fairPlayStreaming)
    private var certificate: Data?
    private var keySessions: [Int: FairPlayVideoKeySession] = [:]
    private var keyOwners: [Data: Int] = [:]
    private var keyRequests: [Data: AVContentKeyRequest] = [:]
    private var contentKeys: Set<Data> = []
    /// The CDM's keys by key ID, attached to their samples as they're enqueued (a key from an skd:// request isn't
    /// matched to samples by key ID on its own).
    private var contentKeyObjects: [Data: AVContentKey] = [:]
    private var keyBatch: [AVContentKeyRequest] = []
    private var lastKeySession: Int?
    private var flushQueued = false

    private var media = 0
    private var tracks: [Int: FairPlayVideoTrack] = [:]
    private let display = AVSampleBufferDisplayLayer()
    private let audio = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private var videoLane: FairPlayVideoLane!
    private var audioLane: FairPlayVideoLane!
    private var serials = 0
    private var ended = false
    private var started = false
    private var stalled = false
    private var pendingTarget = Double.nan
    private var seekSeq = 0
    private var appliedSeq = 0
    private var wantsPlay = false
    private var rate = 1.0
    private var volume = 1.0
    private var pageMuted = false
    private var duration = 0.0
    private var boundary: Any?
    private var boundaryTime = Double.nan
    private var observers: [NSObjectProtocol] = []
    private let view = FairPlayVideoLayerView(frame: .zero)
    private var ticker: Timer?
    private var hasRect = false
    private var rect = NSRect.zero
    private var scale = 2.0
    private var rectVisible = false
    private var showing = false
    private var reportedPlaying = false
    private var failed = false
    private var licenseFailed = false
    private var endedSent = false
    private var displayAwake: NSObjectProtocol?
    private var pip: AVPictureInPictureController?
    private var inPip = false
    private(set) var licensed = false
    private(set) var requestedKeys = 0
    private var closed = false

    init(tab: EngineTab, frame: String, origin: String) {
        self.tab = tab
        self.frame = frame
        self.origin = origin
        super.init()
        keys.setDelegate(self, queue: keyQueue)
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        sync.addRenderer(display)
        sync.addRenderer(audio)
        videoLane = FairPlayVideoLane(renderer: display.sampleBufferRenderer, video: true)
        audioLane = FairPlayVideoLane(renderer: audio, video: false)
        observers.append(NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                                                object: audio, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            self.restart(self.audioLane, at: self.position)
        })
        for recipient in [display as AnyObject, audio as AnyObject] {
            if let r = recipient as? AVContentKeyRecipient { keys.addContentKeyRecipient(r) }
        }
        let clip = CALayer()
        clip.masksToBounds = true
        clip.addSublayer(display)
        view.layer = clip
        view.wantsLayer = true
        view.isHidden = true
        let t = Timer(timeInterval: kTick, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        muteChanged()
    }

    var isActive: Bool { media != 0 && !closed }

    // MARK: Page messages

    func handle(_ op: String, _ d: [String: Any]) {
        switch op {
        case "certificate":
            if let c = Self.base64(d["data"], kMaxPartChars), !c.isEmpty, c.count <= kMaxKeyData {
                certificate = c
                flushKeyRequests()
            }
            return
        case "request": if let s = Self.whole(d["session"], 1, Int(Int32.max)) { keyRequest(d, session: s) }; return
        case "update": if let s = Self.whole(d["session"], 1, Int(Int32.max)) { keyUpdate(d, session: s) }; return
        case "closeSession": if let s = Self.whole(d["session"], 1, Int(Int32.max)) { keySessions[s] = nil }; return
        default: break
        }
        guard let m = Self.whole(d["media"], 1, Int(Int32.max)) else { return }
        if op == "attach" { return attach(m) }
        guard m == media else { return }
        switch op {
        case "detach": detach()
        case "buffer": buffer(d)
        case "append": append(d)
        case "remove": remove(d)
        case "dropBuffer": dropBuffer(d)
        case "end": ended = d["ended"] as? Bool ?? false; lanesChanged()
        case "duration":
            if let v = Self.bounded(d["duration"], 0, 1e8), v != duration { duration = v; onChange?() }
        case "play": wantsPlay = true; applyRate()
        case "pause": wantsPlay = false; applyRate()
        case "seek": seek(d)
        case "rate": if let r = Self.bounded(d["rate"], 0.0625, 16) { rate = r }; applyRate()
        case "volume":
            if let v = Self.bounded(d["volume"], 0, 1) { volume = v }
            pageMuted = d["muted"] as? Bool ?? false
            muteChanged()
        case "rect": setRect(d)
        case "pip":
            if d["enter"] as? Bool == true { if !startPictureInPicture() { deliverPictureInPicture() } }
            else if inPip { pip?.stopPictureInPicture() } else { deliverPictureInPicture() }
        default: break
        }
    }

    private func deliver(_ event: [String: Any]) {
        guard let tab, !tab.isClosed, let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = PageScripts.shared?.callDocument(tab, frame: frame, origin: origin, part: FairPlayVideo.part, kind: "event", json: json)
    }

    func failAt(_ step: String, reason: String) {
        guard !failed, media != 0 else { return }
        failed = true
        deliver(["event": "failed", "media": media, "step": step])
        resetPlayback()
        if let tab, step != "player" || reason != "setting off" {
            NotificationCenter.default.post(name: FairPlayBridge.failed, object: tab, userInfo: ["step": step])
        }
        onChange?()
    }

    func close() {
        guard !closed else { return }
        closed = true
        ticker?.invalidate()
        ticker = nil
        keepDisplayAwake(false)
        pip?.stopPictureInPicture()
        pip = nil
        resetPlayback()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        view.removeFromSuperview()
        keys.setDelegate(nil, queue: nil)
        keys.expire()
        tracks = [:]
        media = 0
        onChange?()
    }

    func muteChanged() {
        var muted = pageMuted || (tab?.isMuted ?? false)
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_FAIRPLAY_AUDIBLE"] != "1" { muted = true }
        #endif
        audio.isMuted = muted
        audio.volume = Float(volume)
    }

    private func attach(_ m: Int) {
        resetPlayback()
        tracks = [:]
        media = m
        announcedKeys = []
        ended = false
        seekSeq = 0
        appliedSeq = 0
        wantsPlay = false
        failed = false
        hasRect = false
        showing = false
        duration = 0
    }

    private func detach() {
        resetPlayback()
        tracks = [:]
        media = 0
        showing = false
        duration = 0
        place()
        onChange?()
    }

    private func buffer(_ d: [String: Any]) {
        guard let b = Self.whole(d["buffer"], 1, 64), let mime = Self.text(d["mime"], 256), !mime.isEmpty else { return }
        var track = tracks[b]
        if track == nil {
            guard tracks.count < kMaxBuffers else { return }
            track = FairPlayVideoTrack(buffer: b)
            tracks[b] = track
        }
        track?.video = mime.lowercased().hasPrefix("video/")
    }

    private func append(_ d: [String: Any]) {
        guard let b = Self.whole(d["buffer"], 1, 64), let seq = Self.whole(d["seq"], 0, Int(Int32.max)),
              let parts = Self.whole(d["parts"], 1, kMaxParts), let part = Self.whole(d["part"], 0, parts - 1),
              let track = tracks[b], let data = Self.base64(d["data"], kMaxPartChars) else { return }
        if part == 0 {
            track.assemblySeq = seq
            track.assemblyNext = 0
            track.assembly = Data()
        }
        guard track.assemblySeq == seq, track.assemblyNext == part, var assembly = track.assembly,
              assembly.count + data.count <= kMaxUnitBytes else {
            track.assemblySeq = -1
            track.assembly = nil
            return
        }
        assembly.append(data)
        track.assembly = assembly
        track.assemblyNext = part + 1
        guard part + 1 == parts else { return }
        let unit = assembly
        track.assembly = nil
        track.assemblySeq = -1
        let kind = Self.text(d["kind"], 16)
        if kind == "init" {
            if track.initData == unit { return }
            track.initData = unit
            track.kid = FairPlayMP4.initKeyID(unit)
            track.timescale = FairPlayMP4.initTimescale(unit)
            if !track.parse(unit) { failAt("playback", reason: track.parseError ?? "parse") }
            announceKeyData(track)
            return
        }
        guard kind == "segment", track.initData != nil, let start = Self.bounded(d["start"], -1e6, 1e8),
              Self.bounded(d["end"], start, 1e8) != nil else { return }
        if !track.parse(unit) { return failAt("playback", reason: track.parseError ?? "parse") }
        announceKeyData(track)
        let decodeTime = FairPlayMP4.fragmentDecodeTime(unit)
        let offset = decodeTime >= 0 && track.timescale > 0 ? start - Double(decodeTime) / Double(track.timescale) : 0
        store(track.parsedVideo, in: videoLane, offset: offset, kid: track.kid, bytes: unit.count)
        store(track.parsedAudio, in: audioLane, offset: offset, kid: track.kid, bytes: unit.count)
        track.parsedVideo = []
        track.parsedAudio = []
        if ended { ended = false }
        lanesChanged()
    }

    /// As Safari does: the init data of an encrypted track goes to the page as the element's `encrypted` event
    /// (initDataType "sinf"), once per key ID; the page answers with its own key session.
    private var announcedKeys: Set<Data> = []
    private func announceKeyData(_ track: FairPlayVideoTrack) {
        let found = track.pendingKeyData
        track.pendingKeyData = []
        for data in found {
            let ids = FairPlayMP4.sinfKeyIDs(data)
            guard !ids.isEmpty, !ids.allSatisfy(announcedKeys.contains) else { continue }
            announcedKeys.formUnion(ids)
            deliver(["event": "encrypted", "media": media, "type": "sinf", "data": data.base64EncodedString()])
        }
    }

    private func store(_ buffers: [CMSampleBuffer], in lane: FairPlayVideoLane, offset: Double, kid: Data?, bytes: Int) {
        guard !buffers.isEmpty else { return }
        var samples: [CMSampleBuffer] = []
        var start = Double.infinity, end = -Double.infinity
        for b in buffers {
            for s in singleSamples(b, offset: abs(offset) > 1e-4 ? offset : 0) {
                start = min(start, startOf(s))
                end = max(end, endOf(s))
                samples.append(s)
            }
        }
        guard !samples.isEmpty, start.isFinite, end.isFinite else { return }
        serials += 1
        lane.store(FairPlayVideoSegment(samples: samples, start: start, end: max(end, start + 0.001), bytes: bytes, kid: kid, serial: serials),
                   position: position)
    }

    private func remove(_ d: [String: Any]) {
        guard let b = Self.whole(d["buffer"], 1, 64), let start = Self.bounded(d["start"], -1e6, 1e8),
              let end = Self.number(d["end"]), end >= start, let track = tracks[b] else { return }
        (track.video ? videoLane : audioLane).remove(from: start, to: end, position: position)
        lanesChanged()
    }

    private func dropBuffer(_ d: [String: Any]) {
        guard let b = Self.whole(d["buffer"], 1, 64), let track = tracks.removeValue(forKey: b) else { return }
        if !tracks.values.contains(where: { $0.video == track.video }) {
            (track.video ? videoLane : audioLane).remove(from: -1e6, to: 1e8, position: position)
        }
        lanesChanged()
    }

    private func seek(_ d: [String: Any]) {
        guard let seq = Self.whole(d["seq"], 1, Int(Int32.max)), let time = Self.bounded(d["time"], 0, 1e8) else { return }
        seekSeq = seq
        endedSent = false
        seek(to: time)
    }

    private func setRect(_ d: [String: Any]) {
        guard let x = Self.bounded(d["x"], -1e5, 1e5), let y = Self.bounded(d["y"], -1e5, 1e5),
              let w = Self.bounded(d["width"], 0, 1e5), let h = Self.bounded(d["height"], 0, 1e5),
              let s = Self.bounded(d["scale"], 0.25, 8) else { return }
        rect = NSRect(x: x, y: y, width: w, height: h)
        scale = s
        rectVisible = (d["visible"] as? Bool ?? false) && w > 0 && h > 0
        hasRect = true
        place()
    }

    // MARK: Playback

    private func keepDisplayAwake(_ awake: Bool) {
        guard awake != (displayAwake != nil) else { return }
        if awake {
            displayAwake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if let a = displayAwake {
            ProcessInfo.processInfo.endActivity(a)
            displayAwake = nil
        }
    }

    private func resetPlayback() {
        clearBoundary()
        sync.setRate(0, time: .zero)
        videoLane.clear()
        audioLane.clear()
        display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audio.flush()
        started = false
        stalled = false
        pendingTarget = .nan
        endedSent = false
    }

    private var lanes: [FairPlayVideoLane] {
        var v = !videoLane.stored.isEmpty, a = !audioLane.stored.isEmpty
        for t in tracks.values { if t.video { v = true } else { a = true } }
        return (v ? [videoLane!] : []) + (a ? [audioLane!] : [])
    }

    var position: Double {
        if !started { return pendingTarget.isFinite ? pendingTarget : 0 }
        let now = CMTimeGetSeconds(sync.currentTime())
        return now.isFinite ? now : 0
    }

    private func bufferedEnd(from time: Double) -> Double {
        let ls = lanes
        guard !ls.isEmpty else { return .nan }
        var end = Double.infinity
        for l in ls {
            let e = l.endFrom(time)
            if !e.isFinite { return .nan }
            end = min(end, e)
        }
        return end
    }

    private var bufferedEnd: Double { bufferedEnd(from: position) }

    private var naturalStart: Double {
        var start = -Double.infinity
        for l in lanes {
            guard let first = l.stored.first else { return .nan }
            start = max(start, first.start)
        }
        return start.isFinite ? max(start, 0) : .nan
    }

    private func canStart(at time: Double) -> Bool {
        let end = bufferedEnd(from: time)
        return end.isFinite && (end - time >= kResumeAhead || ended || (duration > 0 && end >= duration - 0.1))
    }

    private func seek(to time: Double) {
        if canStart(at: time) { return start(at: time) }
        clearBoundary()
        started = false
        stalled = false
        pendingTarget = time
        sync.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90000))
        halt(videoLane)
        halt(audioLane)
        onChange?()
    }

    private func start(at time: Double) {
        pendingTarget = .nan
        started = true
        stalled = false
        sync.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90000))
        restart(videoLane, at: time)
        restart(audioLane, at: time)
        appliedSeq = seekSeq
        clearBoundary()
        armBoundary()
        applyRate()
        onChange?()
    }

    private func halt(_ lane: FairPlayVideoLane) {
        idle(lane)
        if lane.video { display.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) } else { audio.flush() }
        lane.enqueued = []
        lane.feed = nil
        lane.dirty = false
        lane.blocked = false
        lane.promisedFloor = .invalid
    }

    private func restart(_ lane: FairPlayVideoLane, at time: Double) {
        halt(lane)
        lane.from = time
        lane.cue(at: time)
        feed(lane)
    }

    private func idle(_ lane: FairPlayVideoLane) {
        lane.renderer.stopRequestingMediaData()
        lane.requesting = false
    }

    private func feed(_ lane: FairPlayVideoLane) {
        guard started, lane.feed != nil, !lane.blocked, !lane.requesting else { return }
        lane.requesting = true
        lane.renderer.requestMediaDataWhenReady(on: .main) { [weak self, weak lane] in
            guard let self, let lane else { return }
            self.pump(lane)
        }
        pump(lane)
    }

    private func pump(_ lane: FairPlayVideoLane) {
        while lane.requesting && lane.renderer.isReadyForMoreMediaData {
            guard let segment = lane.feed else { return idle(lane) }
            if lane.feedIndex >= segment.samples.count {
                guard let next = lane.following(segment) else { return idle(lane) }
                lane.feed = next
                lane.feedIndex = 0
                continue
            }
            if let kid = segment.kid, !contentKeys.contains(kid) {
                lane.blocked = true
                return idle(lane)
            }
            let sample = segment.samples[lane.feedIndex]
            lane.feedIndex += 1
            var queued = sample
            if endOf(sample) <= lane.from + 1e-4 {
                if !lane.video { continue }
                guard let hidden = hiddenCopy(sample) else { continue }
                queued = hidden
            }
            if let kid = segment.kid, let key = contentKeyObjects[kid] {
                _ = AVSampleBufferAttachContentKey(queued, key, nil)
            }
            if lane.video, let f = CMSampleBufferGetFormatDescription(queued), lane.format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: f) }) ?? true {
                lane.format = f
            }
            lane.renderer.enqueue(queued)
            lane.enqueued.insert(ObjectIdentifier(segment))
            if lane.video, #available(macOS 14.4, *) {
                let floor = lane.upcomingFloor()
                if floor.isNumeric && (!lane.promisedFloor.isNumeric || CMTimeCompare(floor, lane.promisedFloor) > 0) {
                    lane.promisedFloor = floor
                    display.sampleBufferRenderer.__expectMinimumUpcomingSampleBufferPresentationTime(floor)
                }
            }
        }
    }

    private func lanesChanged() {
        guard media != 0, !failed else { return }
        if !started {
            let target = pendingTarget.isFinite ? pendingTarget : naturalStart
            if target.isFinite && canStart(at: target) { start(at: target) }
            return
        }
        let now = position
        for lane in [videoLane!, audioLane!] {
            if (lane.dirty || lane.feed == nil) && lane.containing(now) != nil { restart(lane, at: now) } else { feed(lane) }
        }
        armBoundary()
        let end = bufferedEnd
        if stalled && end.isFinite && (end - now >= kResumeAhead || ended) {
            stalled = false
            applyRate()
        }
        if ended && !endedSent && (!end.isFinite || now >= end - 0.05) { reachedEnd() }
    }

    private func keysChanged() {
        for lane in [videoLane!, audioLane!] where lane.blocked {
            lane.blocked = false
            feed(lane)
        }
    }

    private func armBoundary() {
        let end = started ? bufferedEnd : .nan
        if end == boundaryTime || (end.isNaN && boundaryTime.isNaN) { return }
        clearBoundary()
        guard end.isFinite else { return }
        boundaryTime = end
        boundary = sync.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: max(0, end - 0.02), preferredTimescale: 90000))],
                                                queue: .main) { [weak self] in self?.reachedBufferedEnd() }
    }

    private func clearBoundary() {
        if let b = boundary { sync.removeTimeObserver(b) }
        boundary = nil
        boundaryTime = .nan
    }

    private func reachedBufferedEnd() {
        guard started else { return }
        let now = position, end = bufferedEnd
        if end.isFinite && now < end - 0.05 { clearBoundary(); return armBoundary() }
        if ended { return reachedEnd() }
        if stalled { return }
        stalled = true
        applyRate()
    }

    private func reachedEnd() {
        guard !endedSent else { return }
        endedSent = true
        wantsPlay = false
        applyRate()
        deliver(["event": "ended", "media": media])
    }

    private func applyRate() {
        let r: Float = wantsPlay && started && !stalled && !endedSent && !failed ? Float(rate) : 0
        guard sync.rate != r else { return }
        sync.rate = r
        onChange?()
        pip?.invalidatePlaybackState()
        if started { deliver(["event": "time", "media": media, "seq": appliedSeq, "time": position, "playing": r > 0]) }
    }

    private func tick() {
        guard let tab, !tab.isClosed else { return close() }
        place()
        if tab.isMuted != audio.isMuted && !pageMuted { muteChanged() }
        guard started else { return keepDisplayAwake(false) }
        let renderer = display.sampleBufferRenderer
        if renderer.status == .failed { return failAt("playback", reason: renderer.error?.localizedDescription ?? "video renderer failed") }
        if audio.status == .failed { return failAt("playback", reason: audio.error?.localizedDescription ?? "audio renderer failed") }
        let now = position
        if renderer.requiresFlushToResumeDecoding { restart(videoLane, at: now) }
        let playing = CMTimebaseGetRate(sync.timebase) > 0
        keepDisplayAwake(playing && !endedSent)
        if playing && !showing { showing = true; place() }
        if playing != reportedPlaying { reportedPlaying = playing; onChange?() }
        deliver(["event": "time", "media": media, "seq": appliedSeq, "time": now, "playing": playing, "dropped": 0])
        if playing && !stalled && !endedSent {
            let end = bufferedEnd
            if !end.isFinite || now >= end - 0.03 { reachedBufferedEnd() }
        }
        if videoLane.bytes + audioLane.bytes > kMaxStoredBytes {
            videoLane.evict(before: now - kKeepBehind, position: now)
            audioLane.evict(before: now - kKeepBehind, position: now)
        }
    }

    /// The layer view over the page's video rectangle (the page reports it in CSS pixels).
    private func place() {
        guard let tab else { view.isHidden = true; return }
        let content = tab.view
        guard media != 0, showing, hasRect, rectVisible, let host = content.superview, let window = content.window,
              !content.isHiddenOrHasHiddenAncestor else {
            if !view.isHidden { view.isHidden = true }
            return
        }
        if view.superview !== host || host.subviews.last !== view {
            host.addSubview(view, positioned: .above, relativeTo: nil)
        }
        let backing = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        let k = scale / backing
        var inContent = NSRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
        if !content.isFlipped { inContent.origin.y = content.bounds.height - inContent.maxY }
        let full = content.convert(inContent, to: host)
        let visible = full.intersection(content.frame)
        guard !visible.isEmpty else { view.isHidden = true; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if view.frame != visible { view.frame = visible }
        var layerFrame = full.offsetBy(dx: -visible.minX, dy: -visible.minY)
        if host.isFlipped { layerFrame.origin.y = visible.height - layerFrame.maxY }
        if !inPip && display.frame != layerFrame { display.frame = layerFrame }
        if display.contentsScale != backing { display.contentsScale = backing }
        CATransaction.commit()
        if view.isHidden != inPip { view.isHidden = inPip }
    }

    // MARK: Tray, Now Playing, media keys

    func trayState() -> EngineMediaSession? {
        guard isActive, started || wantsPlay else { return nil }
        var s = EngineMediaSession()
        s.playback = CMTimebaseGetRate(sync.timebase) > 0 || (wantsPlay && !endedSent) ? .playing : .paused
        s.active = true
        s.duration = duration > 0 ? duration : nil
        s.position = position
        s.rate = rate
        s.actions = ["play", "pause", "seekto"]
        return s
    }

    func remote(_ action: String, _ value: Double) {
        var event: [String: Any] = ["event": "remote", "media": media, "command": action]
        if action == "seekto" { event["time"] = value }
        deliver(event)
    }

    // MARK: Keys

    private func keyRequest(_ d: [String: Any], session: Int) {
        guard let keySystem = Self.text(d["keySystem"], 32), keySystem.hasPrefix("com.apple.fps"),
              let type = Self.text(d["type"], 16), let data = Self.base64(d["data"], kMaxPartChars), !data.isEmpty, data.count <= kMaxKeyData
        else { return }
        var ids: [Data] = []
        var initialization: Data?
        var skd: String?
        if type == "sinf" {
            ids = FairPlayMP4.sinfKeyIDs(data)
            initialization = data
        } else if type == "cenc", let pssh = FairPlayMP4.fairPlayPssh(data) {
            ids = FairPlayMP4.fairPlayKeyIDs(pssh)
            initialization = try? JSONSerialization.data(withJSONObject: ["pssh": pssh.base64EncodedString()])
        } else if type == "skd", let uri = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian),
                  let kid = FairPlayMP4.keyID(fromSkd: uri) {
            ids = [kid]
            skd = uri.trimmingCharacters(in: .controlCharacters)
            initialization = data
        }
        guard !ids.isEmpty, let initialization else {
            return deliver(["event": "keys", "session": session, "ok": false])
        }
        if keySessions[session] == nil && keySessions.count >= kMaxKeySessions { return }
        let owner = keySessions[session] ?? FairPlayVideoKeySession()
        owner.keySystem = keySystem
        owner.raw = keySystem != "com.apple.fps.3_0"
        keySessions[session] = owner
        lastKeySession = session
        for kid in ids { keyOwners[kid] = session }
        if let skd {
            // HLS-style FairPlay: the key URI is the request's identifier.
            keys.processContentKeyRequest(withIdentifier: skd, initializationData: nil, options: nil)
        } else {
            keys.processContentKeyRequest(withIdentifier: nil, initializationData: initialization, options: ["InitializationDataType": type])
        }
    }

    private func keyUpdate(_ d: [String: Any], session: Int) {
        guard let data = Self.base64(d["data"], kMaxPartChars), let owner = keySessions[session], !data.isEmpty, data.count <= kMaxKeyData else { return }
        if owner.raw {
            let kid = owner.awaitingKid
            owner.awaitingKid = nil
            if let kid, let request = keyRequests.removeValue(forKey: kid) {
                licensed = true
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: data))
            }
            return askPageForNextRawKey(session)
        }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        for e in entries {
            guard let kid = Self.base64(e["keyID"], 64), let request = keyRequests.removeValue(forKey: kid) else { continue }
            if let ckc = Self.base64(e["payload"], kMaxPartChars), !ckc.isEmpty {
                licensed = true
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
            } else {
                request.processContentKeyResponseError(NSError(domain: "AircFairPlayVideo", code: 1))
            }
        }
    }

    private func keyID(of request: AVContentKeyRequest) -> Data? {
        if let d = request.identifier as? Data, d.count == 16 { return d }
        if let s = request.identifier as? String, let kid = FairPlayMP4.keyID(fromSkd: s) { return kid }
        guard let initialization = request.initializationData, !initialization.isEmpty else { return nil }
        if let o = (try? JSONSerialization.jsonObject(with: initialization)) as? [String: Any], let p = o["pssh"] as? String,
           let pssh = Data(base64Encoded: p) {
            return FairPlayMP4.fairPlayKeyIDs(pssh).first
        }
        if let kid = FairPlayMP4.sinfKeyIDs(initialization).first { return kid }
        if let uri = String(data: initialization, encoding: .utf8) { return FairPlayMP4.keyID(fromSkd: uri) }
        return nil
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, let kid = self.keyID(of: keyRequest) else { return }
            self.keyRequests[kid] = keyRequest
            self.keyBatch.append(keyRequest)
            guard !self.flushQueued else { return }
            self.flushQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.flushQueued = false
                self?.flushKeyRequests()
            }
        }
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        contentKeySession(session, didProvide: keyRequest)
    }

    private func flushKeyRequests() {
        guard let certificate, !keyBatch.isEmpty else { return }
        let batch = keyBatch
        keyBatch = []
        var byOwner: [Int: [AVContentKeyRequest]] = [:]
        for r in batch {
            let kid = keyID(of: r)
            guard let owner = kid.flatMap({ keyOwners[$0] }) ?? lastKeySession, keySessions[owner] != nil else { continue }
            if let kid { keyOwners[kid] = owner }
            byOwner[owner, default: []].append(r)
        }
        for (owner, requests) in byOwner { askPage(owner, for: requests, certificate: certificate) }
    }

    private func askPage(_ session: Int, for requests: [AVContentKeyRequest], certificate: Data) {
        let group = DispatchGroup()
        let lock = NSLock()
        var entries: [(kid: Data, spc: Data)] = []
        for r in requests {
            guard let kid = keyID(of: r) else { continue }
            group.enter()
            // An skd:// request names its content by the URI's text (as Safari's players send it); others by key ID.
            let contentID = (r.identifier as? String).flatMap { $0.lowercased().hasPrefix("skd://") ? Data($0.dropFirst(6).utf8) : nil } ?? kid
            r.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentID, options: nil) { spc, _ in
                if let spc { lock.lock(); entries.append((kid, spc)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, let owner = self.keySessions[session], !entries.isEmpty else { return }
            self.requestedKeys += entries.count
            if owner.raw {
                owner.rawQueue.append(contentsOf: entries)
                return self.askPageForNextRawKey(session)
            }
            let json = entries.map { ["keyID": $0.kid.base64EncodedString(), "payload": $0.spc.base64EncodedString()] }
            if let message = try? JSONSerialization.data(withJSONObject: json) {
                self.deliver(["event": "message", "session": session, "data": message.base64EncodedString()])
            }
        }
    }

    /// Raw FairPlay (com.apple.fps.1_0, 2_0): one SPC at a time; the page's licence answers that key.
    private func askPageForNextRawKey(_ session: Int) {
        guard let owner = keySessions[session] else { return }
        while owner.awaitingKid == nil, !owner.rawQueue.isEmpty {
            let e = owner.rawQueue.removeFirst()
            guard keyRequests[e.kid] != nil else { continue }
            owner.awaitingKid = e.kid
            deliver(["event": "message", "session": session, "data": e.spc.base64EncodedString()])
        }
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        let key = keyRequest.contentKey
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, let kid = self.keyID(of: keyRequest) else { return }
            self.contentKeys.insert(kid)
            if let key { self.contentKeyObjects[kid] = key }
            self.keysChanged()
            guard let owner = self.keyOwners[kid], let ks = self.keySessions[owner] else { return }
            ks.succeeded = true
            self.deliver(["event": "keys", "session": owner, "ok": true, "keyIDs": [kid.base64EncodedString()]])
        }
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            let kid = self.keyID(of: keyRequest)
            let owner = kid.flatMap { self.keyOwners[$0] }
            let ks = owner.flatMap { self.keySessions[$0] }
            if let kid { self.keyRequests[kid] = nil }
            if let ks, let owner, ks.raw, ks.awaitingKid == kid {
                ks.awaitingKid = nil
                self.askPageForNextRawKey(owner)
            }
            guard let ks, let owner, (err as NSError).code != kContentKeyTimedOut else { return }
            self.deliver(["event": "keys", "session": owner, "ok": false])
            if ks.succeeded || self.licenseFailed { return }
            self.licenseFailed = true
            self.failAt("license", reason: err.localizedDescription)
        }
    }

    // MARK: Picture in picture (macOS's own window, on the sample-buffer layer)

    private func startPictureInPicture() -> Bool {
        guard started, AVPictureInPictureController.isPictureInPictureSupported() else { return false }
        if pip == nil {
            pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: display, playbackDelegate: self))
            pip?.delegate = self
        }
        guard let pip, pip.isPictureInPicturePossible else { return false }
        pip.startPictureInPicture()
        return true
    }

    private func deliverPictureInPicture() { deliver(["event": "pip", "media": media, "active": inPip]) }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        inPip = true
        deliverPictureInPicture()
        place()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        inPip = false
        deliverPictureInPicture()
        place()
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        inPip = false
        deliverPictureInPicture()
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        remote(playing ? "play" : "pause", 0)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { sync.rate == 0 }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        let delta = CMTimeGetSeconds(skipInterval)
        DispatchQueue.main.async { [weak self] in
            if let self { self.deliver(["event": "seekBy", "media": self.media, "delta": delta]) }
            completionHandler()
        }
    }

    var isInPictureInPicture: Bool { inPip }

    // MARK: Input

    private static func whole(_ v: Any?, _ low: Int, _ high: Int) -> Int? {
        guard let n = FairPlayBridge.jsonNumber(v) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), d >= Double(low), d <= Double(high) else { return nil }
        return Int(d)
    }
    private static func number(_ v: Any?) -> Double? {
        guard let n = FairPlayBridge.jsonNumber(v), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func bounded(_ v: Any?, _ low: Double, _ high: Double) -> Double? {
        guard let d = number(v), d >= low, d <= high else { return nil }
        return d
    }
    private static func text(_ v: Any?, _ max: Int) -> String? {
        guard let s = v as? String, s.utf8.count <= max else { return nil }
        return s
    }
    private static func base64(_ v: Any?, _ max: Int) -> Data? {
        guard let s = text(v, max), !s.isEmpty else { return nil }
        return Data(base64Encoded: s)
    }

    #if AIRC_TESTING
    var testState: [String: Any] {
        ["session": true, "media": media, "started": started, "rate": sync.rate, "time": position,
         "videoSegments": videoLane.stored.count, "audioSegments": audioLane.stored.count,
         "keys": contentKeys.count, "requestedKeys": requestedKeys, "licensed": licensed, "failed": failed,
         "layerShown": !view.isHidden && view.superview != nil, "layerFrame": NSStringFromRect(view.frame),
         "videoStatus": display.sampleBufferRenderer.status.rawValue, "audioMuted": audio.isMuted, "pip": inPip,
         "videoError": display.sampleBufferRenderer.error.map { "\($0)" } ?? "", "announcedKeys": announcedKeys.count,
         "attachableKeys": contentKeyObjects.count]
    }
    #endif
}

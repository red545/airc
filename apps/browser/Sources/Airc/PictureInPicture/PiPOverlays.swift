// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// Airc's controls in the engine's picture in picture (SB-55): the engine keeps Chromium's window and video surface,
/// hides Chromium's own controls and hosts these views above the video (engine/PIP.md "App overlay"). A video (and
/// the Little Arc mini player, the same window) gets `PiPControlsView`; a site's own Document PiP (Meet) gets the
/// slim `PiPTopBarView`. Everything they do goes through the tab's Media Session (engine/PASS13.md), its sound, and the
/// existing back-to-tab and close; their state comes from the media tray's session observers (no polling).
final class PiPOverlays {
    static let shared = PiPOverlays()

    private final class Entry {
        weak var page: EngineTab?
        weak var controls: PiPControlsView?
        weak var bar: PiPTopBarView?
        var session = EngineMediaSession()
        /// When the session was read (the scrubber runs on from there).
        var at: CFTimeInterval = 0
        var resumeAfterScrub = false
        init(page: EngineTab) { self.page = page }
    }

    weak var library: MediaLibrary?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var installed = false
    /// What the scripted checks saw the controls do (action, value).
    private(set) var performed: [(String, Double)] = []

    /// MediaLibrary.attach: hand the engine our overlay (Chromium only; WebKit's picture in picture is the system's).
    func attach(_ library: MediaLibrary) {
        self.library = library
        #if canImport(AircCore)
        guard !installed, library.controller?.app?.engine is ChromiumEngine else { return }
        installed = PiPEngineOverlay.install { [weak self] tab, info in self?.provide(tab, info) }
        #endif
    }

    private var engine: (EngineMedia & BrowserEngine)? { library?.controller?.app?.engine as? (EngineMedia & BrowserEngine) }

    // MARK: The engine asks

    #if canImport(AircCore)
    private func provide(_ tab: AircTab, _ info: [String: Any]) -> NSView? {
        guard let page = tab.delegate as? EngineTab else { return nil }
        entries = entries.filter { $0.value.controls != nil || $0.value.bar != nil }
        let e = Entry(page: page)
        entries[ObjectIdentifier(page)] = e
        if info["kind"] as? String == "document" {
            let h = (info["topBarHeight"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? PiPLayout.topBarHeight
            let bar = PiPTopBarView(barHeight: max(h, 1))
            bar.host = URLRules.displayHost(page.url?.absoluteString ?? "")
            bar.close.action = { [weak self, weak page] in if let page { self?.close(page, pause: false) } }
            bar.back.action = { [weak self, weak page] in if let page { self?.backToTab(page) } }
            e.bar = bar
            return bar
        }
        let v = PiPControlsView()
        v.actions = actions(for: page)
        e.controls = v
        e.session = engine?.mediaSession(of: page) ?? EngineMediaSession()
        e.at = CACurrentMediaTime()
        refresh(e)
        // Shown for a moment as it arrives, as Arc's.
        DispatchQueue.main.async { [weak v] in v?.flashControls() }
        return v
    }
    #endif

    // MARK: News from the media tray (MediaCenter)

    func sessionChanged(_ page: EngineTab, _ s: EngineMediaSession) {
        guard let e = entries[ObjectIdentifier(page)], e.controls != nil else { return }
        e.session = s
        e.at = CACurrentMediaTime()
        refresh(e)
    }

    /// The page's sound or title changed.
    func pageChanged(_ page: EngineTab) {
        guard let e = entries[ObjectIdentifier(page)] else { return }
        refresh(e)
    }

    private func refresh(_ e: Entry) {
        guard let page = e.page, let v = e.controls else { return }
        v.update(Self.state(e.session, muted: page.isMuted, at: e.at))
    }

    static func state(_ s: EngineMediaSession, muted: Bool, at: CFTimeInterval) -> PiPControlsState {
        var st = PiPControlsState()
        st.call = s.isCall
        st.playing = s.playback == .playing
        st.canPlayPause = s.actions.contains("play") || s.actions.contains("pause")
        st.canSkip = s.actions.contains("seekto") || s.actions.contains("seekforward") || s.actions.contains("seekbackward")
        st.hasPrevious = s.actions.contains("previoustrack")
        st.hasNext = s.actions.contains("nexttrack")
        if let d = s.duration, d > 0, d.isFinite, s.actions.contains("seekto") {
            st.clock = PiPScrubber.Clock(duration: d, position: min(d, max(0, s.position ?? 0)), rate: s.rate > 0 ? s.rate : 1,
                                         playing: st.playing && s.rate != 0, at: at)
        }
        st.muted = muted
        st.hasMicrophone = s.actions.contains("togglemicrophone")
        st.microphoneOn = s.microphoneOn
        st.hasCamera = s.actions.contains("togglecamera")
        st.cameraOn = s.cameraOn
        st.canLeave = s.actions.contains("hangup")
        return st
    }

    // MARK: What the controls do

    @discardableResult
    private func perform(_ action: String, _ value: Double = 0, on page: EngineTab) -> Bool {
        performed.append((action, value))
        return engine?.performMediaAction(action, value: value, in: page) ?? false
    }

    private func actions(for page: EngineTab) -> PiPControlsView.Actions {
        var a = PiPControlsView.Actions()
        let key = ObjectIdentifier(page)
        a.close = { [weak self, weak page] in if let page { self?.close(page, pause: true) } }
        a.backToTab = { [weak self, weak page] in if let page { self?.backToTab(page) } }
        a.playPause = { [weak self, weak page] in
            guard let self, let page, let e = self.entries[key] else { return }
            let playing = e.session.playback == .playing
            guard self.perform(playing ? "pause" : "play", on: page) else { return }
            // The glyph flips now; the session confirms it.
            e.session.playback = playing ? .paused : .playing
            if let p = e.controls?.state.clock?.now() { e.session.position = p }
            e.at = CACurrentMediaTime()
            self.refresh(e)
        }
        a.skip = { [weak self, weak page] seconds in
            guard let self, let page, let e = self.entries[key] else { return }
            let now = e.controls?.state.clock?.now() ?? e.session.position ?? 0
            // Exactly 15 s where the page takes a position (Arc's skip); else the page's own seek step.
            if e.session.actions.contains("seekto") {
                let to = min(e.session.duration ?? .infinity, max(0, now + seconds))
                guard self.perform("seekto", to, on: page) else { return }
                e.session.position = to
                e.at = CACurrentMediaTime()
                self.refresh(e)
            } else {
                self.perform(seconds < 0 ? "seekbackward" : "seekforward", abs(seconds), on: page)
            }
        }
        a.track = { [weak self, weak page] next in
            guard let self, let page else { return }
            self.perform(next ? "nexttrack" : "previoustrack", on: page)
        }
        a.mute = { [weak self, weak page] in
            guard let self, let page else { return }
            page.isMuted.toggle()
            self.performed.append(("mute", page.isMuted ? 1 : 0))
            if let e = self.entries[key] { self.refresh(e) }
            self.library?.controller.flatMap { $0.tabID(for: page) }.map { self.library?.media?.pageChanged($0) }
        }
        a.seek = { [weak self, weak page] seconds, final in
            guard let self, let page, let e = self.entries[key] else { return }
            guard self.perform("seekto", seconds, on: page), final else { return }
            e.session.position = seconds
            e.at = CACurrentMediaTime()
        }
        a.scrub = { [weak self, weak page] began in
            // Arc pauses while you scrub and plays on after (its DragState.wasPlayingAtDragBegin).
            guard let self, let page, let e = self.entries[key] else { return }
            if began {
                e.resumeAfterScrub = e.session.playback == .playing && e.session.actions.contains("pause")
                if e.resumeAfterScrub { self.perform("pause", on: page) }
            } else if e.resumeAfterScrub {
                e.resumeAfterScrub = false
                self.perform("play", on: page)
                e.session.playback = .playing
                e.at = CACurrentMediaTime()
                self.refresh(e)
            }
        }
        a.microphone = { [weak self, weak page] in if let page { self?.perform("togglemicrophone", on: page) } }
        a.camera = { [weak self, weak page] in if let page { self?.perform("togglecamera", on: page) } }
        a.leave = { [weak self, weak page] in if let page { self?.perform("hangup", on: page) } }
        return a
    }

    /// ✕: the picture in picture goes; a video pauses (as Arc's and Chrome's), a call goes on in its tab.
    func close(_ page: EngineTab, pause: Bool) {
        if pause, let e = entries[ObjectIdentifier(page)], e.session.playback == .playing, !e.session.isCall {
            perform("pause", on: page)
        }
        performed.append(("close", 0))
        #if canImport(AircCore)
        (library?.controller?.app?.engine as? ChromiumEngine)?.closePictureInPicture(page)
        #endif
    }

    /// Back to Tab: the tab (or the Little Arc window) comes forward and the picture in picture closes; it plays on.
    func backToTab(_ page: EngineTab) {
        performed.append(("backToTab", 0))
        #if canImport(AircCore)
        guard let c = library?.controller, let chromium = c.app?.engine as? ChromiumEngine else { return }
        if c.app?.options.isAutomated == true, c.app?.littleArcs.contains(where: { $0.page === page }) != true,
           let id = c.tabID(for: page), let tab = c.store.tab(id) {
            // Scripted runs never take the focus from the person using the Mac: the tab, without activating Airc.
            if let sid = tab.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: false) }
            c.show(id)
            c.window.orderFront(nil)
        } else {
            chromium.pictureInPictureRequestsTab?(page)
        }
        chromium.closePictureInPicture(page)
        #endif
    }

    // MARK: For the scripted checks

    func controls(for page: EngineTab) -> PiPControlsView? { entries[ObjectIdentifier(page)]?.controls }
    func topBar(for page: EngineTab) -> PiPTopBarView? { entries[ObjectIdentifier(page)]?.bar }
    func clearPerformed() { performed = [] }
}

#if canImport(AircCore)
/// The engine's overlay hook, called by name so the app also runs on a framework without it (Chromium's own controls
/// then stay).
enum PiPEngineOverlay {
    typealias Provider = @convention(block) (AircTab, NSDictionary) -> NSView?
    static let selector = NSSelectorFromString("setPictureInPictureOverlayProvider:")
    static var available: Bool { class_getClassMethod(AircEngine.self, selector) != nil }

    static func install(_ provide: @escaping (AircTab, [String: Any]) -> NSView?) -> Bool {
        guard let m = class_getClassMethod(AircEngine.self, selector) else { return false }
        typealias F = @convention(c) (AnyClass, Selector, Provider?) -> Void
        let block: Provider = { tab, info in provide(tab, info as? [String: Any] ?? [:]) }
        unsafeBitCast(method_getImplementation(m), to: F.self)(AircEngine.self, selector, block)
        return true
    }

    /// The tab's open picture in picture as the engine sees it (kind, window, appOverlay, chromeControls), if any.
    static func state(_ page: EngineTab, in chromium: ChromiumEngine) -> [String: Any]? {
        guard let core = chromium.core(of: page), core.responds(to: NSSelectorFromString("pictureInPictureState")) else { return nil }
        return core.value(forKey: "pictureInPictureState") as? [String: Any]
    }
}
#endif

// MARK: - Document PiP top bar

/// Meet's own picture-in-picture window gets a slim top bar like Arc's (`DocumentPiPTopBarView`): ✕ on the left, the
/// site, Back to Tab on the right, on Arc's dark bar with a hairline under it. It covers Chromium's own bar exactly;
/// the page below keeps its own controls. The bar's background drags the window (the engine's snapping policy).
final class PiPTopBarView: NSView {
    let barHeight: CGFloat
    let close = PiPButton(symbol: "xmark", size: 10, label: "Close")
    let back = PiPButton(symbol: "pip.exit", size: 11, style: .pill, label: "Back to Tab")
    private let bar = CALayer()
    private let hairline = CALayer()
    private let hostLabel = NSTextField(labelWithString: "")
    var host = "" { didSet { hostLabel.stringValue = host } }

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
        super.init(frame: .zero)
        wantsLayer = true
        for l in [bar, hairline] { l.actions = LayerImage.noActions; layer?.addSublayer(l) }
        bar.backgroundColor = PiPLayout.topBarColor.cgColor
        hairline.backgroundColor = PiPLayout.topBarHairline.cgColor
        hostLabel.font = PiPLayout.topBarFont
        hostLabel.textColor = PiPLayout.topBarText
        hostLabel.lineBreakMode = .byTruncatingTail
        addSubview(hostLabel)
        back.title = "Back to Tab"
        for b in [close, back] { addSubview(b) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = barHeight, s = PiPLayout.topBarButton, i = PiPLayout.topBarInset
        let px = 1 / (window?.backingScaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hairline.frame = NSRect(x: 0, y: h - px, width: w, height: px)
        CATransaction.commit()
        close.frame = NSRect(x: i, y: (h - s) / 2, width: s, height: s)
        // No title on a narrow window: the glyph alone.
        back.title = w < 260 ? nil : "Back to Tab"
        let bw = back.pillWidth(height: s)
        back.frame = NSRect(x: w - i - bw, y: (h - s) / 2, width: bw, height: s)
        let lh: CGFloat = 16
        hostLabel.frame = NSRect(x: close.frame.maxX + 8, y: (h - lh) / 2, width: max(0, back.frame.minX - close.frame.maxX - 16), height: lh)
    }

    /// The bar: a button, or the bar itself (window-drag background). Below it: the page's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard p.y >= 0, p.y < barHeight, p.x >= 0, p.x < bounds.width else { return nil }
        for b in [close, back] where !b.isHidden && b.frame.contains(p) { return b }
        return self
    }

    /// A click on the bar's background does nothing (the engine also keeps it from Chromium's bar underneath).
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

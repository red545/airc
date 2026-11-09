// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import QuartzCore

// Arc's picture-in-picture controls, drawn by Airc over the video (SB-55): the same view in the engine's video PiP,
// the Little Arc mini player and the call window, so they look identical. Positions are in PiPLayout.
//
// Every control takes a press as separate mouseDown / mouseDragged / mouseUp calls, with no nested tracking loop:
// in the engine's PiP window the engine forwards a press on them straight to the view, so Airc never activates
// (engine/PIP.md "App overlay"). Hit testing returns a control or nil, never the controls view itself: the video
// around them stays the window's drag background.

/// A control the PiP windows hand presses to (CallPanel and the engine both ask for it).
protocol PiPInteractive: NSView {}

/// A spring on a layer key path (design.md §5), or a plain set with Reduce Motion.
enum PiPMotion {
    static func spring(_ layer: CALayer, _ keyPath: String, from start: Any? = nil, to value: Any, response: Double, damping: Double = 1) {
        let from = start ?? layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 2 * damping * a.stiffness.squareRoot()
        a.fromValue = from
        a.toValue = value
        a.duration = a.settlingDuration
        layer.add(a, forKey: "pip.\(keyPath)")
    }
}

// MARK: - Buttons

/// A round glass button (✕, mute, track, the call's buttons), a bare glyph (play, skip), or the Back to Tab pill.
/// Its plate, glyph and title live in one sublayer, `body`, which scales about its centre on hover and press.
final class PiPButton: NSView, PiPInteractive {
    enum Style { case plate, bare, pill }

    var symbol: String { didSet { if symbol != oldValue { redraw() } } }
    var glyphSize: CGFloat { didSet { if glyphSize != oldValue { redraw() } } }
    var tint: NSColor = PiPLayout.glyph { didSet { if tint != oldValue { redraw() } } }
    /// The plate behind the glyph (`plate` and `pill`): glass by default, red for Leave, white for a muted microphone.
    var fill: NSColor? { didSet { updatePlate() } }
    var style: Style { didSet { redraw() } }
    /// The pill's words, when there's room ("Back to Tab").
    var title: String? { didSet { if title != oldValue { redraw() } } }
    /// Tooltip and accessibility label.
    var label: String { didSet { setAccessibilityLabel(label); toolTip = label } }
    var action: (() -> Void)?
    /// Extra motion on a press (the skip arrow's turn, the play glyph's bounce).
    var onPress: ((PiPButton) -> Void)?
    let body = CALayer()
    let glyph = CALayer()
    private let text = CATextLayer()
    private var hovered = false
    private var pressed = false

    init(symbol: String, size: CGFloat, style: Style = .plate, label: String) {
        self.symbol = symbol
        self.glyphSize = size
        self.style = style
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        for l in [body, glyph, text] as [CALayer] { l.actions = LayerImage.noActions }
        body.cornerCurve = .continuous
        layer?.addSublayer(body)
        glyph.contentsGravity = .center
        body.addSublayer(glyph)
        text.alignmentMode = .left
        text.truncationMode = .end
        body.addSublayer(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pill's width for its title at this height.
    func pillWidth(height: CGFloat) -> CGFloat {
        guard style == .pill, let title, !title.isEmpty else { return height }
        let w = (title as NSString).size(withAttributes: [.font: PiPLayout.pillFont]).width
        return ceil(PiPLayout.pillPadding * 2 + glyphSize + PiPLayout.pillGap + w)
    }

    private func redraw() {
        LayerImage.set(LayerImage.symbol(symbol, size: glyphSize, weight: style == .bare ? .semibold : .bold, color: tint), on: glyph, in: self)
        // A bare glyph over bright video needs its own soft shadow.
        glyph.shadowColor = NSColor.black.cgColor
        glyph.shadowOpacity = style == .bare ? 0.35 : 0
        glyph.shadowRadius = 4
        glyph.shadowOffset = .zero
        let showsTitle = style == .pill && !(title ?? "").isEmpty
        text.isHidden = !showsTitle
        if showsTitle {
            text.string = NSAttributedString(string: title ?? "", attributes: [.font: PiPLayout.pillFont, .foregroundColor: tint])
            text.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
        updatePlate()
        needsLayout = true
    }

    private func updatePlate() {
        let color: NSColor
        if style == .bare {
            color = .clear
        } else if let fill {
            color = fill.withAlphaComponent(fill.alphaComponent * (pressed ? 0.8 : hovered ? 0.92 : 1))
        } else {
            color = pressed ? PiPLayout.platePressed : hovered ? PiPLayout.plateHover : PiPLayout.plate
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.bounds = bounds
        body.position = CGPoint(x: bounds.midX, y: bounds.midY)
        body.cornerRadius = min(bounds.width, bounds.height) / 2
        if style == .pill, !text.isHidden {
            let g = glyphSize + 4
            glyph.frame = NSRect(x: PiPLayout.pillPadding - 2, y: (bounds.height - g) / 2, width: g, height: g)
            let h = ceil(PiPLayout.pillFont.ascender - PiPLayout.pillFont.descender)
            let x = PiPLayout.pillPadding + glyphSize + PiPLayout.pillGap
            text.frame = NSRect(x: x, y: (bounds.height - h) / 2 - 0.5, width: max(0, bounds.width - x - PiPLayout.pillPadding + 2), height: h)
        } else {
            glyph.frame = bounds
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ on: Bool) {
        hovered = on
        updatePlate()
        PiPMotion.spring(body, "transform.scale", to: on ? PiPLayout.hoverScale : 1, response: 0.22, damping: 0.8)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        updatePlate()
        PiPMotion.spring(body, "transform.scale", to: 0.92, response: 0.16)
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        pressed = false
        updatePlate()
        PiPMotion.spring(body, "transform.scale", to: hovered ? PiPLayout.hoverScale : 1, response: 0.3, damping: 0.55)
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(self)
        action?()
    }
}

// MARK: - Scrubber

/// The progress bar with elapsed and remaining time (Arc's `BasicScrubber`). Between the session's updates the bar
/// runs on its own with a Core Animation animation from the position and rate (no polling, no per-frame work on the
/// main thread); the labels tick once a second while they show. A drag seeks; dragging upwards slows it ("Drag
/// upwards to seek precisely").
final class PiPScrubber: NSView, PiPInteractive {
    struct Clock: Equatable {
        var duration: Double
        var position: Double
        var rate: Double
        var playing: Bool
        /// When `position` was read (CACurrentMediaTime).
        var at: CFTimeInterval
        func now(_ t: CFTimeInterval = CACurrentMediaTime()) -> Double {
            guard playing, rate > 0 else { return position }
            return min(duration, max(0, position + (t - at) * rate))
        }
    }

    /// `final`: the release (else a live seek during the drag).
    var onSeek: ((Double, _ final: Bool) -> Void)?
    var onScrub: ((_ began: Bool) -> Void)?
    var showsTimes = true { didSet { elapsed.isHidden = !showsTimes; remaining.isHidden = !showsTimes; needsLayout = true } }
    private(set) var clock: Clock?
    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    let elapsed = PiPScrubber.label(.left)
    let remaining = PiPScrubber.label(.right)
    private let speed = PiPScrubber.label(.center)
    private var tick: Timer?
    private var hovered = false
    private var drag: (startX: CGFloat, startY: CGFloat, startValue: Double, value: Double, lastSent: CFTimeInterval)?
    var isScrubbing: Bool { drag != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, fill, knob] { l.actions = LayerImage.noActions; layer?.addSublayer(l) }
        track.backgroundColor = PiPLayout.barTrack.cgColor
        fill.backgroundColor = PiPLayout.barFill.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        knob.backgroundColor = PiPLayout.barFill.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.3
        knob.shadowRadius = 2
        knob.shadowOffset = .zero
        knob.opacity = 0
        for l in [elapsed, remaining, speed] { addSubview(l) }
        speed.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback position")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func label(_ alignment: NSTextAlignment) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = PiPLayout.timeFont
        l.textColor = PiPLayout.timeColor
        l.alignment = alignment
        l.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.4)
            s.shadowBlurRadius = 3
            return s
        }()
        return l
    }

    /// Only the bar band takes presses (the labels above it are part of the video).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let band = NSRect(x: 0, y: barY - PiPLayout.draggableHeight / 2, width: bounds.width, height: PiPLayout.draggableHeight)
        return band.contains(p) && clock != nil ? self : nil
    }

    private var barY: CGFloat { bounds.height - PiPLayout.draggableHeight / 2 }

    func set(_ c: Clock?) {
        guard !isScrubbing else { clock = c; return }
        clock = c
        isHidden = c == nil
        redraw()
    }

    /// The labels tick only while they're on screen.
    func setTicking(_ on: Bool) {
        tick?.invalidate()
        tick = nil
        guard on, let c = clock, c.playing, c.rate > 0 else { return updateLabels() }
        updateLabels()
        // On the next whole second of media time, then every second of it.
        let now = c.now()
        let first = (1 - now.truncatingRemainder(dividingBy: 1)) / c.rate
        let t = Timer(fire: Date().addingTimeInterval(max(0.05, first)), interval: 1 / c.rate, repeats: true) { [weak self] _ in self?.updateLabels() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    override func layout() {
        super.layout()
        redraw()
        let h: CGFloat = 14, w = max(0, bounds.width / 2 - 4)
        let y = barY - PiPLayout.timeRise - h / 2
        elapsed.frame = NSRect(x: 0, y: y, width: w, height: h)
        remaining.frame = NSRect(x: bounds.width - w, y: y, width: w, height: h)
        speed.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
    }

    private func redraw() {
        let barH = hovered || isScrubbing ? PiPLayout.barHoverHeight : PiPLayout.barHeight
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: barY - barH / 2, width: w, height: barH)
        track.cornerRadius = barH / 2
        fill.cornerRadius = barH / 2
        fill.bounds = CGRect(x: 0, y: 0, width: fill.bounds.width, height: barH)
        fill.position = CGPoint(x: 0, y: barY)
        knob.bounds = CGRect(x: 0, y: 0, width: PiPLayout.knob, height: PiPLayout.knob)
        knob.cornerRadius = PiPLayout.knob / 2
        knob.opacity = hovered || isScrubbing ? 1 : 0
        CATransaction.commit()
        place(value: drag?.value ?? clock?.now())
        updateLabels()
    }

    /// The bar at `value` seconds; while playing, it then runs to the end on its own.
    private func place(value: Double?) {
        fill.removeAnimation(forKey: "run")
        knob.removeAnimation(forKey: "run")
        guard let c = clock, c.duration > 0, let v = value else { return }
        let w = bounds.width
        let x = w * CGFloat(min(1, max(0, v / c.duration)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds.size.width = x
        knob.position = CGPoint(x: x, y: barY)
        CATransaction.commit()
        guard drag == nil, c.playing, c.rate > 0, v < c.duration else { return }
        // Time runs linearly: this is the media clock, not UI motion.
        let left = (c.duration - v) / c.rate
        for (l, key, to) in [(fill, "bounds.size.width", w as Any), (knob, "position.x", w as Any)] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = key == "bounds.size.width" ? x : x
            a.toValue = to
            a.duration = left
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.isRemovedOnCompletion = false
            a.fillMode = .forwards
            l.add(a, forKey: "run")
        }
    }

    private func updateLabels() {
        guard let c = clock, c.duration > 0 else { return }
        let v = drag?.value ?? c.now()
        elapsed.stringValue = Self.time(v)
        remaining.stringValue = "−" + Self.time(max(0, c.duration - v))
        setAccessibilityValue(Self.time(v))
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.isFinite ? max(0, s) : 0)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let band = NSRect(x: 0, y: barY - PiPLayout.draggableHeight / 2, width: bounds.width, height: PiPLayout.draggableHeight)
        addTrackingArea(NSTrackingArea(rect: band, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; redraw() }
    override func mouseExited(with event: NSEvent) { hovered = false; if !isScrubbing { redraw() } }

    override func mouseDown(with event: NSEvent) {
        guard let c = clock, c.duration > 0, bounds.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let v = c.duration * Double(min(1, max(0, p.x / bounds.width)))
        drag = (p.x, p.y, v, v, 0)
        onScrub?(true)
        redraw()
        send(final: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let c = clock, bounds.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Every PiPLayout.precisionStep points above the bar halves the speed, down to an eighth.
        let up = max(0, d.startY - p.y)
        let halvings = min(3, Int(up / PiPLayout.precisionStep))
        let factor = 1 / pow(2, Double(halvings))
        d.value = min(c.duration, max(0, d.startValue + Double((p.x - d.startX) / bounds.width) * c.duration * factor))
        drag = d
        speed.isHidden = halvings == 0
        speed.stringValue = ["", "½× speed", "¼× speed", "⅛× speed"][halvings]
        elapsed.alphaValue = halvings == 0 ? 1 : 0
        remaining.alphaValue = halvings == 0 ? 1 : 0
        place(value: d.value)
        updateLabels()
        // Live seeks, a few a second: the picture follows the drag.
        if CACurrentMediaTime() - d.lastSent > 0.15 { send(final: false) }
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        send(final: true)
        if let c = clock, let d = drag { clock = Clock(duration: c.duration, position: d.value, rate: c.rate, playing: c.playing, at: CACurrentMediaTime()) }
        drag = nil
        speed.isHidden = true
        elapsed.alphaValue = 1
        remaining.alphaValue = 1
        onScrub?(false)
        redraw()
    }

    private func send(final: Bool) {
        guard var d = drag else { return }
        d.lastSent = CACurrentMediaTime()
        drag = d
        onSeek?(d.value, final)
    }
}

// MARK: - The controls

/// A container laid out from the top-left.
final class PiPFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the controls show: a video's playback or a call's microphone, camera and leave.
struct PiPControlsState: Equatable {
    var playing = false
    var canPlayPause = false
    var canSkip = false
    var hasPrevious = false
    var hasNext = false
    var clock: PiPScrubber.Clock?
    var muted = false
    var canMute = true
    /// A call: the meeting controls instead of the playback ones.
    var call = false
    var hasMicrophone = false
    var microphoneOn = false
    var hasCamera = false
    var cameraOn = false
    var canToggleMicrophone = false
    var canToggleCamera = false
    var canLeave = false
    /// The engine's PiP can go back to its tab; Arc's title.
    var backToTab = true
}

/// The overlay: ✕ and – (hide: playback goes on, the tray brings it back) and Back to Tab in the top corners (and mute),
/// the play controls in the middle, the scrubber at the bottom, or a call's buttons; a soft scrim behind them. Arc's
/// corner has just those two buttons, so collapsing to the pill is Esc's. They fade in when the pointer moves over the
/// window and out after PiPLayout.hideAfter of stillness.
final class PiPControlsView: NSView {
    struct Actions {
        var close: () -> Void = {}
        var stopPlayback: () -> Void = {}
        var backToTab: () -> Void = {}
        var playPause: () -> Void = {}
        var skip: (_ seconds: Double) -> Void = { _ in }
        var track: (_ next: Bool) -> Void = { _ in }
        var mute: () -> Void = {}
        var seek: (_ seconds: Double, _ final: Bool) -> Void = { _, _ in }
        var scrub: (_ began: Bool) -> Void = { _ in }
        var microphone: () -> Void = {}
        var camera: () -> Void = {}
        var leave: () -> Void = {}
        var pictureInPicture: () -> Void = {}
        var suppressSite: () -> Void = {}
    }

    /// Full-page call hosts reserve a permanent bar; the site owns its call controls.
    var fullPage = false { didSet { apply(); needsLayout = true; flashControls() } }
    static let fullPageBarHeight: CGFloat = 48
    var actions = Actions()
    var mediaTitle = "" { didSet { miniPlayer.update() } }
    var canSuppressSite = false
    lazy var miniPlayer = MiniPlayerPresentation(self)
    let hide = PiPButton(symbol: "minus", size: 11, label: "Hide Mini Player")
    /// Collapse to the pill (Esc). Not in the corner: Arc's has ✕ and – only.
    let minimize = PiPButton(symbol: "chevron.down", size: 11, label: "Collapse Mini Player")
    private(set) var state = PiPControlsState()
    private(set) var sizeClass: PiPLayout.SizeClass = .regular
    /// Everything, scrim included: faded as one. Laid out from the top, like this view.
    let content = PiPFlippedView()
    private let dim = CALayer()
    private let topScrim = CAGradientLayer()
    private let bottomScrim = CAGradientLayer()
    let close = PiPButton(symbol: "xmark", size: 11, label: "Close")
    let back = PiPButton(symbol: "pip.exit", size: 12, style: .pill, label: "Back to Tab")
    let mute = PiPButton(symbol: "speaker.wave.2.fill", size: 11, label: "Mute")
    let previous = PiPButton(symbol: "backward.end.fill", size: 15, style: .bare, label: "Previous Track")
    let skipBack = PiPButton(symbol: "gobackward.15", size: 21, style: .bare, label: "Skip Back 15 Seconds")
    let play = PiPButton(symbol: "play.fill", size: 28, style: .bare, label: "Play")
    let skipAhead = PiPButton(symbol: "goforward.15", size: 21, style: .bare, label: "Skip Ahead 15 Seconds")
    let next = PiPButton(symbol: "forward.end.fill", size: 15, style: .bare, label: "Next Track")
    let scrubber = PiPScrubber()
    let mic = PiPButton(symbol: "mic.fill", size: 15, label: "Mute Microphone")
    let camera = PiPButton(symbol: "video.fill", size: 15, label: "Turn Camera Off")
    let leave = PiPButton(symbol: "phone.down.fill", size: 15, label: "Leave Call")
    private var hovering = false
    private var hideWork: DispatchWorkItem?
    private(set) var controlsVisible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        content.wantsLayer = true
        content.layer?.opacity = 0
        addSubview(content)
        dim.backgroundColor = NSColor.black.withAlphaComponent(PiPLayout.scrimDim).cgColor
        for (g, top) in [(topScrim, true), (bottomScrim, false)] {
            g.colors = [NSColor.black.withAlphaComponent(PiPLayout.scrimEdge).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: top ? 0 : 1)
            g.endPoint = CGPoint(x: 0.5, y: top ? 1 : 0)
        }
        for l in [dim, topScrim, bottomScrim] as [CALayer] { l.actions = LayerImage.noActions; content.layer?.addSublayer(l) }
        for b in [hide, close, back, mute, previous, skipBack, play, skipAhead, next, mic, camera, leave] { content.addSubview(b) }
        minimize.isHidden = true // not shown (Esc collapses)
        content.addSubview(scrubber)
        back.title = "Back to Tab"
        hide.action = { [weak self] in self?.miniPlayer.hideWindow() }
        minimize.action = { [weak self] in self?.miniPlayer.setMinimized(true) }
        close.action = { [weak self] in self?.actions.close() }
        back.action = { [weak self] in self?.actions.backToTab() }
        mute.action = { [weak self] in self?.actions.mute() }
        play.action = { [weak self] in self?.actions.playPause() }
        // The new glyph pops in from a little smaller.
        play.onPress = { b in PiPMotion.spring(b.glyph, "transform.scale", from: 0.78, to: 1, response: 0.34, damping: 0.55) }
        skipBack.action = { [weak self] in self?.actions.skip(-PiPLayout.skipSeconds) }
        skipAhead.action = { [weak self] in self?.actions.skip(PiPLayout.skipSeconds) }
        for (b, sign) in [(skipBack, CGFloat(1)), (skipAhead, CGFloat(-1))] {
            // Arc's AnimatedSkipButton: the arrow turns the way it skips, then springs back.
            b.onPress = { b in
                let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                turn.values = [0, sign * PiPLayout.skipTurn, 0]
                turn.keyTimes = [0, 0.3, 1]
                turn.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1), CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)]
                turn.duration = 0.42
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { b.glyph.add(turn, forKey: "turn") }
            }
        }
        previous.action = { [weak self] in self?.actions.track(false) }
        next.action = { [weak self] in self?.actions.track(true) }
        mic.action = { [weak self] in if self?.state.canToggleMicrophone == true { self?.actions.microphone() } }
        camera.action = { [weak self] in if self?.state.canToggleCamera == true { self?.actions.camera() } }
        leave.action = { [weak self] in self?.actions.leave() }
        leave.fill = PiPLayout.leave
        scrubber.onSeek = { [weak self] s, final in self?.actions.seek(s, final) }
        scrubber.onScrub = { [weak self] began in
            guard let self else { return }
            self.actions.scrub(began)
            if began { self.hideWork?.cancel() } else { self.scheduleHide(after: PiPLayout.hideAfter) }
        }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return super.keyDown(with: event) }
        if event.keyCode == 53 { miniPlayer.setMinimized(true); return }
        if event.keyCode == 49, state.canPlayPause, !state.call { actions.playPause(); return }
        super.keyDown(with: event)
    }

    func update(_ s: PiPControlsState) {
        guard s != state else { return }
        let wasPlaying = state.playing
        state = s
        apply()
        if wasPlaying != s.playing, controlsVisible { scheduleHide(after: PiPLayout.hideAfter) }
    }

    private func apply() {
        let s = state
        let video = !s.call
        play.symbol = s.playing ? "pause.fill" : "play.fill"
        play.label = s.playing ? "Pause" : "Play"
        play.isHidden = !video || !s.canPlayPause
        mute.symbol = s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        mute.label = s.muted ? "Unmute" : "Mute"
        mute.isHidden = !video || !s.canMute
        back.isHidden = !s.backToTab
        previous.isHidden = !video || !s.hasPrevious
        next.isHidden = !video || !s.hasNext
        mic.isHidden = fullPage || !s.call || !s.hasMicrophone
        camera.isHidden = fullPage || !s.call || !s.hasCamera
        leave.isHidden = fullPage || !s.call || !s.canLeave
        mic.symbol = s.microphoneOn ? "mic.fill" : "mic.slash.fill"
        camera.symbol = s.cameraOn ? "video.fill" : "video.slash.fill"
        // Off: a white plate with a red glyph, so it reads at a glance.
        mic.fill = s.microphoneOn ? nil : NSColor.white
        mic.tint = s.microphoneOn ? PiPLayout.glyph : PiPLayout.off
        camera.fill = s.cameraOn ? nil : NSColor.white
        camera.tint = s.cameraOn ? PiPLayout.glyph : PiPLayout.off
        mic.label = s.microphoneOn ? "Mute Microphone" : "Unmute Microphone"
        camera.label = s.cameraOn ? "Turn Camera Off" : "Turn Camera On"
        if !s.canToggleMicrophone { mic.label = s.microphoneOn ? "Microphone on — control in tab" : "Microphone off — control in tab" }
        if !s.canToggleCamera { camera.label = s.cameraOn ? "Camera on — control in tab" : "Camera off — control in tab" }
        mic.setAccessibilityEnabled(s.canToggleMicrophone)
        camera.setAccessibilityEnabled(s.canToggleCamera)
        miniPlayer.update()
        scrubber.set(video ? s.clock.flatMap { $0.duration > 0 ? $0 : nil } : nil)
        needsLayout = true
    }

    // MARK: Layout (PiPLayout)

    override func layout() {
        super.layout()
        let b = bounds, c = PiPLayout.sizeClass(for: b.size)
        sizeClass = c
        content.frame = b
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.backgroundColor = fullPage ? PiPLayout.topBarColor.cgColor : NSColor.black.withAlphaComponent(PiPLayout.scrimDim).cgColor
        topScrim.isHidden = fullPage
        bottomScrim.isHidden = fullPage
        dim.frame = b
        topScrim.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height * PiPLayout.scrimTopShare)
        bottomScrim.frame = NSRect(x: 0, y: b.height * (1 - PiPLayout.scrimBottomShare), width: b.width, height: b.height * PiPLayout.scrimBottomShare)
        CATransaction.commit()

        let inset = PiPLayout.cornerInset(c), cb = PiPLayout.cornerButton(c)
        for x in [close, mute] { x.glyphSize = PiPLayout.cornerGlyph(c) }
        close.frame = NSRect(x: inset, y: inset, width: cb, height: cb)
        hide.frame = NSRect(x: close.frame.maxX + 4, y: inset, width: cb, height: cb)
        back.title = c == .compact ? nil : "Back to Tab"
        back.glyphSize = PiPLayout.cornerGlyph(c) + 1
        let pw = back.pillWidth(height: PiPLayout.pillHeight(c))
        back.frame = NSRect(x: b.width - inset - pw, y: inset, width: pw, height: PiPLayout.pillHeight(c))
        let muteRight = back.isHidden ? b.width - inset : back.frame.minX - PiPLayout.cornerGap
        mute.frame = NSRect(x: muteRight - cb, y: inset, width: cb, height: cb)

        miniPlayer.update()
        if fullPage {
            let size: CGFloat = 28, inset: CGFloat = 10
            close.frame = NSRect(x: inset, y: 10, width: size, height: size)
            hide.frame = NSRect(x: close.frame.maxX + 4, y: 10, width: size, height: size)
            back.title = "Back to Tab"
            back.frame = NSRect(x: b.width - inset - back.pillWidth(height: size), y: 10,
                                width: back.pillWidth(height: size), height: size)
            for control in [mute, previous, skipBack, play, skipAhead, next, mic, camera, leave] { control.isHidden = true }
            scrubber.isHidden = true
            return
        }

        // Centre row: previous, skip back, play, skip ahead, next (what the session offers; no skips when compact).
        let skips = state.canSkip && c == .regular && !state.call
        skipBack.isHidden = !skips || !state.canPlayPause && !state.canSkip
        skipAhead.isHidden = skipBack.isHidden
        play.glyphSize = PiPLayout.playGlyph(c)
        for x in [previous, next] { x.glyphSize = PiPLayout.trackGlyph(c) }
        for x in [skipBack, skipAhead] { x.glyphSize = PiPLayout.skipGlyph(c) }
        let row: [(PiPButton, CGFloat)] = [(previous, PiPLayout.trackButton(c)), (skipBack, PiPLayout.skipButton(c)),
                                           (play, PiPLayout.playButton(c)), (skipAhead, PiPLayout.skipButton(c)),
                                           (next, PiPLayout.trackButton(c))].filter { !$0.0.isHidden }
        let gap = PiPLayout.centreGap(c)
        let total = row.reduce(0) { $0 + $1.1 } + gap * CGFloat(max(0, row.count - 1))
        var x = (b.width - total) / 2
        let midY = b.height / 2
        for (v, s) in row {
            v.frame = NSRect(x: x, y: midY - s / 2, width: s, height: s)
            x += s + gap
        }

        // Bottom: the scrubber.
        let si = PiPLayout.scrubberInset(c)
        let sh = PiPLayout.draggableHeight + PiPLayout.timeRise + 14
        scrubber.showsTimes = c == .regular
        scrubber.frame = NSRect(x: si, y: b.height - PiPLayout.scrubberBottom(c) - sh + PiPLayout.draggableHeight / 2, width: b.width - 2 * si, height: sh)

        // A call: microphone, camera, leave at the bottom centre.
        let mb = PiPLayout.meetingButton(c), mg = PiPLayout.meetingGap(c)
        let calls = [mic, camera, leave].filter { !$0.isHidden }
        for v in calls { v.glyphSize = PiPLayout.meetingGlyph(c) }
        var mx = (b.width - CGFloat(calls.count) * mb - CGFloat(max(0, calls.count - 1)) * mg) / 2
        for v in calls {
            v.frame = NSRect(x: mx, y: b.height - PiPLayout.meetingBottom(c) - mb, width: mb, height: mb)
            mx += mb + mg
        }
    }

    // MARK: Hit testing

    /// A control, or nil: the rest of the window is the video's (its drag background, or the page's).
    override func hitTest(_ point: NSPoint) -> NSView? {
        if miniPlayer.state.isMinimized {
            let p = miniPlayer.pill.convert(point, from: superview)
            guard miniPlayer.pill.bounds.contains(p) else { return nil }
            if !miniPlayer.play.isHidden, miniPlayer.play.frame.contains(p) { return miniPlayer.play }
            if miniPlayer.title.frame.contains(p) { return miniPlayer.title }
            return nil // pill margins and button gap remain the window's drag background
        }
        guard controlsVisible || scrubber.isScrubbing, !isHidden else { return nil }
        var v = super.hitTest(point)
        while let x = v, !(x is PiPInteractive) { v = x === self || x === content ? nil : x.superview }
        return v
    }

    // MARK: Showing and hiding

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        pointerMoved()
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = true
        pointerMoved()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        guard !scrubber.isScrubbing else { return }
        scheduleHide(after: PiPLayout.hideAfterExit)
    }

    /// The pointer moved over the window: the controls show, and go after a still moment.
    func pointerMoved() {
        setControls(visible: true)
        scheduleHide(after: PiPLayout.hideAfter)
    }

    /// On arrival: shown for a moment, so you see what's there.
    func flashControls() {
        setControls(visible: true)
        scheduleHide(after: PiPLayout.introHold)
    }

    func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        guard !fullPage else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.scrubber.isScrubbing else { return }
            self.setControls(visible: false)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func setControls(visible: Bool) {
        let visible = fullPage || visible
        guard visible != controlsVisible, let l = content.layer else { return }
        controlsVisible = visible
        let spring = visible ? PiPLayout.fadeIn : PiPLayout.fadeOut
        PiPMotion.spring(l, "opacity", to: Float(visible ? 1 : 0), response: spring.response, damping: spring.damping)
        scrubber.setTicking(visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        miniPlayer.attach()
        if window == nil {
            hideWork?.cancel()
            scrubber.setTicking(false)
        }
    }
}

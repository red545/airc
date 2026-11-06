// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

// The sidebar's update button, as in Arc (Arc ref §2.9 "Update banner"): once Sparkle has downloaded and verified an
// update, a pill above the footer reads "New Airc Version Available"; a click restarts into it. Nothing auto-restarts:
// left alone, the update installs when Airc quits. A call, a running download or a page that would ask "Leave site?"
// gets a calm question first. Sparkle's delegate (App/AircUpdateDelegate.swift) drives it; checks inject a fake.

// MARK: - The state

/// A downloaded, verified update waiting to install: Sparkle's immediate-installation block in dev builds, a fake in
/// scripted checks (which never start the real updater).
protocol ReadyUpdate: AnyObject {
    /// "1.0 (202611061200)", for the tooltip and Updates.log.
    var version: String { get }
    /// Installs it and relaunches Airc. Sparkle quits the app the usual way (state is saved, pages may still ask
    /// "Leave site?"); if the quit is cancelled the update stays ready and this can run again.
    func installAndRelaunch()
}

/// The one ready update, if any. Event-driven: Sparkle's callbacks set it, the sidebars listen for `changed`.
final class UpdateCenter {
    static let shared = UpdateCenter()
    static let changed = Notification.Name("AircUpdateCenterChanged")

    private(set) var ready: ReadyUpdate?
    /// One line in Updates.log (the Sparkle delegate sets it; nothing without Sparkle).
    var log: (String) -> Void = { _ in }
    /// Checks replace how the risks of restarting now are found.
    var riskProbe: ((WindowController, @escaping (UpdateRestartRisks) -> Void) -> Void)?
    /// The question on screen (checks answer it).
    private(set) var confirm: UpdateConfirmView?
    private var shownVersions: Set<String> = []
    private var asking = false

    /// A new update is ready (or none is any more).
    func setReady(_ update: ReadyUpdate?) {
        ready = update
        if let update, shownVersions.insert(update.version).inserted {
            Telemetry.shared.record(.featureUsed(.updateReadyShown))
        }
        if update == nil { dismissConfirm() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The button, or the app menu's "Restart to update": restart now, asking first if something would be lost.
    func restart(from controller: WindowController?) {
        guard let update = ready, !asking, confirm == nil else { return }
        Telemetry.shared.record(.featureUsed(.updateRestartClicked))
        guard let c = controller else { return install(update, downloads: false) }
        asking = true
        let probe = riskProbe ?? { c, done in c.updateRestartRisks(done) }
        probe(c) { [weak self, weak c] risks in
            guard let self else { return }
            self.asking = false
            guard let c, self.ready === update else { return }
            if risks.isEmpty {
                self.install(update, downloads: false)
            } else {
                self.log("restart asks first: \(risks.logText)")
                self.ask(risks, in: c, update: update)
            }
        }
    }

    private func ask(_ risks: UpdateRestartRisks, in c: WindowController, update: ReadyUpdate) {
        let model = UpdateConfirmModel(risks: risks, theme: c.currentPalette.resolved)
        let v = UpdateConfirmView(model: model, controller: c)
        model.onAnswer = { [weak self] restart in
            guard let self else { return }
            self.dismissConfirm()
            if restart, self.ready === update { self.install(update, downloads: risks.downloads > 0) }
            else { self.log("restart: not now") }
        }
        c.root.addSubview(v, positioned: .below, relativeTo: c.toast)
        confirm = v
        v.layoutInWindow()
        v.present()
    }

    func dismissConfirm() {
        guard let v = confirm else { return }
        confirm = nil
        guard let layer = v.layer else { return v.removeFromSuperview() }
        layer.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { v.removeFromSuperview() }
    }

    /// Saves what quitting saves, then hands over to Sparkle.
    private func install(_ update: ReadyUpdate, downloads: Bool) {
        log("restart to update \(update.version)")
        if let store = (NSApp.delegate as? AppDelegate)?.store { try? store.flush() }
        // Already answered here: quitting doesn't ask about the downloads a second time.
        if downloads, let engine = MediaLibrary.shared.downloads?.engine {
            let previous = engine.downloadsCloseConfirmation
            engine.downloadsCloseConfirmation = { _, answer in answer(true) }
            // A quit cancelled by "Leave site?" asks again next time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { engine.downloadsCloseConfirmation = previous }
        }
        update.installAndRelaunch()
    }
}

// MARK: - What restarting now would interrupt

struct UpdateRestartRisks: Equatable {
    /// A page uses the camera, microphone or screen (a call).
    var call = false
    var downloads = 0
    /// Pages that would ask "Leave site?".
    var leaveSite = 0

    var isEmpty: Bool { !call && downloads == 0 && leaveSite == 0 }

    /// The question's lines, most serious first.
    var lines: [String] {
        var out: [String] = []
        if call { out.append("Your call ends.") }
        if downloads == 1 { out.append("A download is still running. Restarting cancels it.") }
        if downloads > 1 { out.append("\(downloads) downloads are still running. Restarting cancels them.") }
        if leaveSite == 1 { out.append("A page may have changes that aren’t saved.") }
        if leaveSite > 1 { out.append("\(leaveSite) pages may have changes that aren’t saved.") }
        return out
    }

    var logText: String { "call \(call), downloads \(downloads), leave site \(leaveSite)" }

    /// A page in a call or capturing (muted or silent too).
    static func isCall(activity: SiteActivity, media: EngineMediaSession) -> Bool {
        activity.camera || activity.microphone || activity.screen
            || media.capture.camera || media.capture.microphone || media.capture.screen || media.capture.tab
    }
}

extension WindowController {
    /// Calls, running downloads, and pages that would ask "Leave site?" (each page answers itself, 0.5 s at most).
    func updateRestartRisks(_ done: @escaping (UpdateRestartRisks) -> Void) {
        var risks = UpdateRestartRisks()
        risks.downloads = MediaLibrary.shared.downloads?.runningCount ?? 0
        let site = app?.engine as? EngineSiteControls, media = app?.engine as? EngineMedia
        let live = pages.values.filter { !$0.isClosed }
        risks.call = live.contains {
            UpdateRestartRisks.isCall(activity: site?.siteActivity(of: $0) ?? SiteActivity(),
                                      media: media?.mediaSession(of: $0) ?? EngineMediaSession())
        }
        var waiting = live.count, finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done(risks)
        }
        guard waiting > 0 else { return finish() }
        for page in live {
            page.evaluate(Self.wouldAskBeforeUnload) { answer in
                if (answer as? Bool) == true { risks.leaveSite += 1 }
                waiting -= 1
                if waiting == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
    }
}

// MARK: - The button

/// Above the footer (SidebarView), in the docked and the revealed sidebar alike: a 34 pt pill on a Favorites tile's
/// fill with a hint of the theme's accent, the app icon, "New Airc Version Available" ("Restart to Update" under the
/// pointer) and a restart glyph. With no update it takes no space; it rises on the row spring.
final class UpdateButtonView: NSView {
    static let pillHeight: CGFloat = 34
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 2
    /// Longest first: the first that fits the sidebar's width.
    static let titles = ["New Airc Version Available", "New Version Available", "Update Airc"]
    static let hoverTitle = "Restart to Update"

    weak var controller: WindowController?
    /// The height the sidebar gives it now (animated).
    private(set) var height: CGFloat = 0
    private var target: CGFloat = 0
    var palette: Palette? { didSet { if palette?.resolved != oldValue?.resolved { style() } } }
    private let plate = CALayer()
    private let tint = CALayer()
    private let icon = CALayer()
    private let glyph = CALayer()
    let title = NSTextField(labelWithString: "")
    private(set) var hovered = false { didSet { if hovered != oldValue { style(); needsLayout = true } } }
    private var pressed = false { didSet { if pressed != oldValue { style() } } }
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        for l in [plate, tint, icon, glyph] {
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        for l in [plate, tint] {
            l.cornerRadius = AircRadius.tile
            l.cornerCurve = .continuous
        }
        icon.contents = AppIconImage.image
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        glyph.contentsGravity = .center
        title.font = AircFont.callout.weight(.semibold).appFont
        title.lineBreakMode = .byClipping
        title.maximumNumberOfLines = 1
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        observer = NotificationCenter.default.addObserver(forName: UpdateCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.readyChanged()
        }
        readyChanged(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isShowing: Bool { target > 0 }
    /// The pill, in this view.
    var pillRect: NSRect {
        let inset = AircMetrics.Sidebar.inset
        return NSRect(x: inset, y: bounds.height - Self.bottomInset - Self.pillHeight, width: max(0, bounds.width - 2 * inset),
                      height: Self.pillHeight)
    }

    private func readyChanged(animated: Bool = true) {
        let ready = UpdateCenter.shared.ready
        toolTip = ready.map { "Restart Airc to update to \($0.version)" }
        setAccessibilityLabel(ready.map { _ in "New Airc version available. Restart to update" })
        if ready == nil { hovered = false }
        let h: CGFloat = ready == nil ? 0 : Self.topInset + Self.pillHeight + Self.bottomInset
        guard h != target else { return }
        target = h
        needsLayout = true
        guard animated, let c = controller, window != nil, !isHiddenOrHasHiddenAncestor else { return setHeight(h) }
        c.animator.spring("update-button", from: Double(height), to: Double(h), velocity: 0, spring: Spring(AircSpring.row),
                          update: { [weak self] v in self?.setHeight(CGFloat(v)) }, completion: { [weak self] in self?.setHeight(h) })
    }

    private func setHeight(_ h: CGFloat) {
        height = max(0, h)
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
        MediaLibrary.shared.layoutPrompts()
        UpdateCenter.shared.confirm?.layoutInWindow()
    }

    private func style() {
        guard let palette else { return }
        let r = palette.resolved
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = (hovered ? palette.tileHover : palette.tileFill).cgColor
        tint.backgroundColor = r.accent.nsColor.withAlphaComponent(r.isDark ? 0.16 : 0.10).cgColor
        CATransaction.commit()
        title.textColor = palette.textPrimary
        LayerImage.set(LayerImage.symbol("arrow.clockwise", size: 11, weight: .semibold, color: r.accent.nsColor), on: glyph, in: self)
        // Pressed: the plate shrinks to 0.99 over 70 ms, like a tab's (Arc ref §2.8).
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        let scale = pressed ? CATransform3DMakeScale(0.99, 0.99, 1) : CATransform3DIdentity
        for l in [plate, tint] { l.transform = scale }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let p = pillRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = p
        tint.frame = p
        icon.frame = NSRect(x: p.minX + 9, y: p.midY - 9, width: 18, height: 18)
        glyph.frame = NSRect(x: p.maxX - 10 - 14, y: p.midY - 7, width: 14, height: 14)
        CATransaction.commit()
        let x = icon.frame.maxX + 8, end = glyph.frame.minX - 6
        let available = max(0, end - x)
        let text = hovered ? Self.hoverTitle : Self.titles.first { fits($0, in: available) } ?? Self.titles.last!
        if title.stringValue != text { title.stringValue = text }
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: x, y: floor(p.midY - th / 2), width: available, height: th)
    }

    private func fits(_ s: String, in width: CGFloat) -> Bool {
        guard let font = title.font else { return true }
        return ceil((s as NSString).size(withAttributes: [.font: font]).width) + 4 <= width
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateHover(_ event: NSEvent) {
        hovered = isShowing && pillRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// Outside the pill (its top inset) clicks go through to the sidebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, let s = superview, pillRect.contains(convert(point, from: s)) else { return nil }
        return self
    }

    #if AIRC_TESTING
    /// Presses and releases this view got (the checks' diagnostics).
    private(set) var presses = (down: 0, up: 0)
    #endif

    override func mouseDown(with event: NSEvent) {
        pressed = true
        #if AIRC_TESTING
        presses.down += 1
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        #if AIRC_TESTING
        presses.up += 1
        #endif
        guard pillRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        UpdateCenter.shared.restart(from: controller)
    }

    override func accessibilityPerformPress() -> Bool {
        UpdateCenter.shared.restart(from: controller)
        return true
    }

    /// For the checks: forces the hover look.
    func setHoveredForSnapshot(_ h: Bool) { hovered = h }
}

// MARK: - The question

final class UpdateConfirmModel: ObservableObject {
    let risks: UpdateRestartRisks
    let theme: ResolvedTheme
    /// true: restart now.
    var onAnswer: ((Bool) -> Void)?

    init(risks: UpdateRestartRisks, theme: ResolvedTheme) {
        self.risks = risks
        self.theme = theme
    }
}

/// The downloads' "still running" card (DownloadViews.swift), sized to the sidebar: what would be lost, Restart, and
/// Not Now as the default.
struct UpdateConfirmCard: View {
    @ObservedObject var model: UpdateConfirmModel
    let width: CGFloat
    private var ui: ResolvedTheme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ui.accent.color)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color))
                Text("Restart to update Airc?").aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.risks.lines, id: \.self) { line in
                    Text(line).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Your Spaces and tabs come back as they are.").aircFont(AircFont.callout)
                    .foregroundStyle(ui.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); restart; notNow }
                VStack(alignment: .trailing, spacing: 6) { restart; notNow }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 14)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .onExitCommand { model.onAnswer?(false) }
        .testAnchorRoot()
        .aircTheme(ui)
    }

    private var restart: some View {
        Button("Restart") { model.onAnswer?(true) }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("update.restartAnyway")
    }

    private var notNow: some View {
        Button("Not Now") { model.onAnswer?(false) }.buttonStyle(.airc(.primary, size: .small)).keyboardShortcut(.defaultAction)
            .testAnchor("update.notNow")
    }
}

/// The card's view: the surface panel with the popover shadow, just above the button (or the page's bottom-left when
/// the sidebar is away).
final class UpdateConfirmView: NSView {
    let model: UpdateConfirmModel
    private weak var controller: WindowController?
    private var host: AircFirstClickHostingView<UpdateConfirmCard>

    init(model: UpdateConfirmModel, controller: WindowController) {
        self.model = model
        self.controller = controller
        host = AircFirstClickHostingView(rootView: UpdateConfirmCard(model: model, width: 260))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.popover
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = model.theme.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = model.theme.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        host.safeAreaRegions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    /// Above the button while the sidebar shows it (docked or revealed), else at the page's bottom-left.
    func layoutInWindow() {
        guard let c = controller else { return }
        let button = c.sidebar.update
        let onScreen = button.isShowing && (c.sidebarFraction >= 1 || c.revealController?.isRevealed == true)
        let anchor = onScreen ? c.root.convert(button.pillRect, from: button)
            : NSRect(x: c.card.frame.minX + AircMetrics.Sidebar.inset, y: c.card.frame.maxY - 10, width: 260, height: 0)
        if host.rootView.width != anchor.width { host.rootView = UpdateConfirmCard(model: model, width: anchor.width) }
        let size = host.fittingSize
        let x = min(max(8, anchor.minX), max(8, c.root.bounds.width - size.width - 8))
        frame = NSRect(x: x.rounded(), y: max(8, anchor.minY - 6 - size.height).rounded(), width: size.width, height: size.height)
        host.frame = bounds
    }

    /// Rises 6 pt and fades in on the dialog curve.
    func present() {
        guard let layer else { return }
        let curve = AircCurve.dialog
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 6
        rise.toValue = 0
        rise.duration = curve.duration
        rise.timingFunction = curve.timingFunction
        layer.add(rise, forKey: "rise")
        layer.fade(from: 0, to: 1, duration: 0.15)
    }
}

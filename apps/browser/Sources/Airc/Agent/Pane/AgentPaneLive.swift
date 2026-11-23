// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// The live page card at the top of the transcript (docs/design/agent-ux.md §3, M1): the agent's current page, scaled
/// to the pane at 16:10, with a caption row (site · page — current step) and Take over. The picture is the engine's own
/// output hosted in a second CALayerHost where the engine can (Chromium: AgentPageDriver.liveLayer, no copies), else
/// copies of its frames at most twice a second. Clicking it opens Watch over the page.
struct AgentPaneLiveCard: View {
    @ObservedObject var model: AgentPaneModel
    @ObservedObject private var run = AgentRunCenter.shared
    @Environment(\.aircTheme) private var theme
    @AppStorage("AircAgentPaneLiveCollapsed") private var collapsed = false
    /// The Agents folder row of the agent's page: the folder's rows aren't observable, so this follows its notification
    /// (a Take over button disabled from before the row existed never came back for a real click).
    @State private var rowID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                AgentPaneLivePicture(model: model)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding([.horizontal, .top], 6)
                    .onTapGesture { model.openWatch() }
                    .help("Watch the agent's page")
                    .accessibilityLabel("The agent's page, live")
                    .accessibilityAddTraits(.isButton)
                    .testAnchor("agentpane.live.picture")
            }
            HStack(spacing: 6) {
                AgentPaneSiteIcon(host: host, size: 14)
                Text(caption).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1).truncationMode(.tail)
                    .testAnchor("agentpane.live.caption")
                Spacer(minLength: 4)
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(theme.surfaceTextTertiary.color)
                .help(collapsed ? "Show the page" : "Hide the page")
                .testAnchor("agentpane.live.collapse")
                Button("Take over") { model.takeOver() }.buttonStyle(.airc(.secondary, size: .small))
                    .disabled(rowID == nil)
                    .help("Use the page yourself; the agent waits until you hand it back")
                    .testAnchor("agentpane.takeover")
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.tileFill.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.surfaceBorder.color))
        .testAnchor("agentpane.live")
        .onAppear { rowID = model.liveRowID }
        .onReceive(NotificationCenter.default.publisher(for: AgentActivity.changed)) { _ in rowID = model.liveRowID }
        .onChange(of: run.stepCount) { _, _ in rowID = model.liveRowID }
    }

    private var window: AgentWindow? { run.runWindowID.flatMap { AgentCenter.shared.windows[$0] } }
    private var host: String? { window?.activeTab?.url?.host.map(AgentPaneTimeline.trimmed) }

    /// "Corner Shop · Orders — Clicking ‘Add’".
    private var caption: String {
        let page = window?.activeTab
        let site = host ?? "Starting"
        let title = page?.title ?? ""
        let step = run.approval != nil ? "Waiting for your OK" : (run.steps.last(where: { $0.kind == .action })?.text ?? "Working…")
        return [site, title.isEmpty ? nil : title].compactMap { $0 }.joined(separator: " · ") + " — " + step
    }
}

/// The picture itself: the pane's one picture view (AgentPaneModel.liveView), kept across SwiftUI updates, so the card
/// never starts again from an empty picture when its view is rebuilt (agentux3).
/// Without a pane model (the task page's cards, asidepass) each SwiftUI make is a new view, as before.
struct AgentPaneLivePicture: NSViewRepresentable {
    var model: AgentPaneModel? = nil
    func makeNSView(context: Context) -> AgentPaneLiveView { model?.liveView ?? AgentPaneLiveView(frame: .zero) }
    func updateNSView(_ v: AgentPaneLiveView, context: Context) { v.refresh() }
    static func dismantleNSView(_ v: AgentPaneLiveView, coordinator: ()) { if !v.isPaneOwned { v.stopAll() } }
}

/// The agent's page in the card (agentux3: without flicker, owner feedback 2026-11-20).
/// - Chromium: a second CALayerHost on the context the engine draws the agent's page into (zero copies, the page's own
///   frame rate). Chromium replaces its CALayerHost (a new context id) when the page gets a new compositor; the card
///   looks 10 times a second, the same way it made its host (the tab's own host first), and swaps in one transaction
///   (new host added, then the old one removed, as Chromium does), so it never shows an empty host. Between two
///   contexts (none found) the last picture stays; only if none comes back within 1.5 s does it go to copies, and the
///   live picture stays until the first copy replaces it.
/// - WebKit (no hosting API): copies at a fixed cadence (`copiesPerSecond`) while the card can be seen; a copy that
///   fails keeps the last picture.
/// - Copies are drawn as the live layer is: the page's width across the card, top-aligned, so switching between the two
///   never moves the page. A new task's window starts from an empty card, never the last task's page.
final class AgentPaneLiveView: NSView {
    /// Frame copies per second where the engine can't host its own output.
    /// (WebKit has no zero-copy hosting; 5 small copies a second read as the page working, at a fraction of Watch's 15.)
    static var copiesPerSecond: Double = 5
    /// How often the live host is checked against the engine's.
    static var liveCheckInterval: Double = 0.1
    private let image = CALayer()
    private let liveBox = CALayer()
    private var live: (layer: CALayer, id: UInt32, flipped: Bool)?
    /// The page the live layer comes from, opted in to keep a hidden view's last frame (engine patch 042): a
    /// navigation to a new view must not empty the context the card shows before the new one exists (cardflicker).
    /// Weak: the card never keeps a closed page alive.
    private var heldTab: (tab: () -> EngineTab?, id: ObjectIdentifier, driver: AgentPageDriver)?
    private var pageSize = CGSize(width: 1280, height: 800)
    /// The copy's pixel size (its aspect places it).
    private var pictureSize: CGSize?
    /// The agent window the picture comes from.
    private var sourceWindow: Int?
    private var scheduled = false
    private var inFlight = false
    private var liveMissSince: CFTimeInterval?
    /// Chromium replaces its host (a new context) and drops the old one in the same main-thread turn. For 2.5 s after any
    /// agent action, a run-loop observer checks once per turn just before Core Animation commits (order below CA's), so
    /// the card's swap goes out in the same commit as Chromium's: never a frame of the dead context. 120 checks a second
    /// in that window back it up, 10 otherwise.
    private var commitObserver: CFRunLoopObserver?
    /// How each swap was found: before the commit, or by the loop (checks report them).
    private(set) var swapsByWatch = 0
    private(set) var swapsByLoop = 0
    private var fastUntil: CFTimeInterval = 0
    private var activityObserver: NSObjectProtocol?
    private var nextCopy: CFTimeInterval = 0
    /// Kept by a pane model across SwiftUI rebuilds (its picture stays when the card is rebuilt).
    var isPaneOwned = false
    /// "live", "copies" or "none" (the checks read it).
    private(set) var mode = "none"
    private(set) var framesShown = 0
    #if AIRC_TESTING
    static weak var current: AgentPaneLiveView?
    /// Views made and live layers installed so far (agentux3's flicker check).
    static var made = 0
    static var installs = 0
    /// "live ctx 123 box shown image hidden 360x225", for the flicker check's state log.
    var debugState: String {
        "\(mode) swaps commit \(swapsByWatch) loop \(swapsByLoop) ctx \(live.map { String($0.id) } ?? "-") box \(liveBox.isHidden ? "hidden" : "shown") image \(image.isHidden ? "hidden" : image.contents == nil ? "empty" : "shown") \(Int(bounds.width))x\(Int(bounds.height)) copies \(framesShown)"
    }
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        image.anchorPoint = .zero
        layer?.addSublayer(image)
        liveBox.anchorPoint = .zero
        liveBox.masksToBounds = true
        liveBox.isHidden = true
        layer?.addSublayer(liveBox)
        #if AIRC_TESTING
        Self.current = self
        Self.made += 1
        #endif
        activityObserver = NotificationCenter.default.addObserver(forName: AgentActivity.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.live != nil else { return }
                self.fastUntil = CACurrentMediaTime() + 2.5
                self.armCommitWatch()
            }
        }
    }

    deinit {
        if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
        if let commitObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), commitObserver, .commonModes) }
    }

    private func armCommitWatch() {
        guard commitObserver == nil else { return }
        // Core Animation commits at before-waiting with order 2000000; this runs just before it.
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if CACurrentMediaTime() > self.fastUntil || self.window == nil {
                    if let o = self.commitObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
                    self.commitObserver = nil
                    return
                }
                self.checkLiveNow()
            }
        }
        commitObserver = o
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }

    /// The live check outside the loop (the engine just replaced its host).
    private func checkLiveNow() {
        guard window != nil, live != nil, let id = AgentRunCenter.shared.runWindowID, let w = AgentCenter.shared.windows[id], let tab = w.activeTab,
              let current = w.driver.liveContextID(tab, in: w.window), current != live?.id, let made = w.driver.liveLayer(tab, in: w.window) else { return }
        swapsByWatch += 1
        installLive(made)
        hold(tab, w.driver)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if AIRC_TESTING
        if window != nil { Self.current = self }
        #endif
        // Out of a window the loop stops by itself; the picture stays for when the card shows again.
        if window != nil { refresh() }
    }

    func stopAll() {
        scheduled = false
        clear()
    }

    /// Starts (or keeps) the picture going; the loop ends by itself once the view leaves its window.
    func refresh() {
        guard window != nil, !scheduled else { return }
        scheduled = true
        tick()
    }

    private func tick() {
        guard scheduled, let win = window else { scheduled = false; return }
        let run = AgentRunCenter.shared
        guard let id = run.runWindowID, let w = AgentCenter.shared.windows[id], let tab = w.activeTab else {
            return again(0.25)
        }
        if sourceWindow != id { clear(); sourceWindow = id }
        if pageSize != w.size { pageSize = w.size; needsLayout = true }
        // The engine's own output while it can host it.
        if AgentWatchView.allowsLive, !AgentWatchView.ignoresOcclusion {
            let current = w.driver.liveContextID(tab, in: w.window)
            let interval = CACurrentMediaTime() < fastUntil ? 1.0 / 120 : Self.liveCheckInterval
            if let live, live.id == current { liveMissSince = nil; return again(interval) }
            if current != nil, let made = w.driver.liveLayer(tab, in: w.window) {
                liveMissSince = nil
                if live != nil { swapsByLoop += 1 }
                installLive(made)
                hold(tab, w.driver)
                return again(interval)
            }
            if live != nil {
                // Between two contexts: the last picture stays.
                let now = CACurrentMediaTime()
                if liveMissSince == nil { liveMissSince = now }
                if now - (liveMissSince ?? now) < 1.5 { return again(Self.liveCheckInterval) }
            }
        }
        // Copies only while this window can be seen, at a fixed cadence.
        guard AgentWatchView.ignoresOcclusion || win.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return again(0.25) }
        let period = 1 / Swift.max(0.5, Self.copiesPerSecond)
        let now = CACurrentMediaTime()
        guard !inFlight else { return again(0.02) }
        guard now >= nextCopy - 0.004 else { return again(nextCopy - now) }
        nextCopy = nextCopy + period < now ? now + period : nextCopy + period
        inFlight = true
        let scale = win.backingScaleFactor * 0.5
        let max = CGSize(width: Swift.max(64, bounds.width * scale), height: Swift.max(40, bounds.height * scale))
        w.driver.watchFrame(tab, maxPixels: max) { [weak self] picture in
            guard let self else { return }
            self.inFlight = false
            guard self.sourceWindow == id else { return self.again(0) }
            if let picture { self.show(picture) }
            self.again(Swift.max(0, self.nextCopy - CACurrentMediaTime()))
        }
    }

    private func again(_ after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.tick() }
    }

    private func show(_ picture: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = picture
        pictureSize = CGSize(width: picture.width, height: picture.height)
        placeImage()
        image.isHidden = false
        // Back from live: the live picture went only now that the copy is there.
        if live != nil {
            live?.layer.removeFromSuperlayer()
            live = nil
            liveBox.isHidden = true
        }
        hold(nil, nil)
        mode = "copies"
        framesShown += 1
        CATransaction.commit()
    }

    private func installLive(_ made: (layer: CALayer, id: UInt32, flipped: Bool)) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let old = live?.layer
        live = made
        mode = "live"
        liveBox.bounds = CGRect(origin: .zero, size: pageSize)
        made.layer.anchorPoint = .zero
        made.layer.frame = liveBox.bounds
        // The new host first, then the old one goes: one commit, never an empty frame.
        liveBox.addSublayer(made.layer)
        old?.removeFromSuperlayer()
        if liveBox.contentsAreFlipped() != made.flipped { liveBox.isGeometryFlipped.toggle() }
        liveBox.isHidden = false
        image.isHidden = true
        image.contents = nil
        pictureSize = nil
        placeLive()
        CATransaction.commit()
        AgentCenter.shared.onEvent?("agentpane-live ctx \(made.id)")
        #if AIRC_TESTING
        Self.installs += 1
        #endif
    }

    /// Only the page the card shows live keeps hidden frames; any other (or none) is back to the engine's default.
    private func hold(_ tab: EngineTab?, _ driver: AgentPageDriver?) {
        let id = tab.map { ObjectIdentifier($0 as AnyObject) }
        if let held = heldTab, held.id != id {
            if let old = held.tab() { held.driver.holdFramesOnHide(old, false) }
            heldTab = nil
        }
        if let tab, let id, let driver, heldTab == nil {
            driver.holdFramesOnHide(tab, true)
            weak var page = tab as AnyObject
            heldTab = ({ page as? EngineTab }, id, driver)
        }
    }

    /// A new task (or none): nothing of the last one shows.
    private func clear() {
        hold(nil, nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live?.layer.removeFromSuperlayer()
        live = nil
        liveBox.isHidden = true
        image.contents = nil
        pictureSize = nil
        image.isHidden = false
        mode = "none"
        liveMissSince = nil
        CATransaction.commit()
    }

    /// The page's width across the card, top-aligned (16:10 shows its top part).
    private func placeLive() {
        let f = bounds.width / max(1, pageSize.width)
        if liveBox.bounds.size != pageSize {
            liveBox.bounds = CGRect(origin: .zero, size: pageSize)
            live?.layer.frame = liveBox.bounds
        }
        liveBox.position = .zero
        liveBox.setAffineTransform(CGAffineTransform(scaleX: f, y: f))
    }

    private func placeImage() {
        guard let s = pictureSize, s.width > 0 else { image.frame = bounds; return }
        image.frame = CGRect(x: 0, y: 0, width: bounds.width, height: (bounds.width * s.height / s.width).rounded())
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeImage()
        placeLive()
        CATransaction.commit()
    }
}

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
                AgentPaneLivePicture()
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

/// The picture itself.
struct AgentPaneLivePicture: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentPaneLiveView { AgentPaneLiveView() }
    func updateNSView(_ v: AgentPaneLiveView, context: Context) { v.refresh() }
    static func dismantleNSView(_ v: AgentPaneLiveView, coordinator: ()) { v.stopAll() }
}

final class AgentPaneLiveView: NSView {
    /// Frame copies per second where the engine can't host its own output.
    static var copiesPerSecond: Double = 2
    private let image = CALayer()
    private let liveBox = CALayer()
    private var live: (layer: CALayer, id: UInt32, flipped: Bool)?
    private var pageSize = CGSize(width: 1280, height: 800)
    private var scheduled = false
    private var inFlight = false
    /// "live", "copies" or "none" (the checks read it).
    private(set) var mode = "none"
    private(set) var framesShown = 0
    #if AIRC_TESTING
    static weak var current: AgentPaneLiveView?
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        image.minificationFilter = .trilinear
        layer?.addSublayer(image)
        liveBox.anchorPoint = .zero
        liveBox.masksToBounds = true
        liveBox.isHidden = true
        layer?.addSublayer(liveBox)
        #if AIRC_TESTING
        Self.current = self
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAll() } else { refresh() }
    }

    func stopAll() {
        removeLive()
        scheduled = false
    }

    /// Starts (or keeps) the picture going; the loop ends by itself once the view leaves its window.
    func refresh() {
        guard window != nil, !scheduled else { return }
        scheduled = true
        tick()
    }

    private func tick() {
        guard scheduled, let win = window else { scheduled = false; return removeLive() }
        let run = AgentRunCenter.shared
        guard let id = run.runWindowID, let w = AgentCenter.shared.windows[id], let tab = w.activeTab else {
            return again(0.5)
        }
        pageSize = w.size
        // The engine's own output while it can host it: only a check once a second that it's still the shown context.
        if AgentWatchView.allowsLive, !AgentWatchView.ignoresOcclusion {
            let current = w.driver.liveContextID(in: w.window)
            if let live, live.id == current { return again(1) }
            removeLive()
            if let made = w.driver.liveLayer(tab, in: w.window) {
                installLive(made)
                return again(1)
            }
        }
        // Copies only while this window can be seen.
        guard AgentWatchView.ignoresOcclusion || win.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return again(0.5) }
        guard !inFlight else { return again(0.5) }
        inFlight = true
        let scale = win.backingScaleFactor * 0.5
        let max = CGSize(width: Swift.max(64, bounds.width * scale), height: Swift.max(40, bounds.height * scale))
        w.driver.watchFrame(tab, maxPixels: max) { [weak self] picture in
            guard let self else { return }
            self.inFlight = false
            if let picture {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.image.contents = picture
                CATransaction.commit()
                self.mode = "copies"
                self.framesShown += 1
            }
            self.again(1 / Swift.max(0.5, Self.copiesPerSecond))
        }
    }

    private func again(_ after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.tick() }
    }

    private func installLive(_ made: (layer: CALayer, id: UInt32, flipped: Bool)) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live = made
        mode = "live"
        liveBox.sublayers?.forEach { $0.removeFromSuperlayer() }
        liveBox.bounds = CGRect(origin: .zero, size: pageSize)
        made.layer.anchorPoint = .zero
        made.layer.frame = liveBox.bounds
        liveBox.addSublayer(made.layer)
        if liveBox.contentsAreFlipped() != made.flipped { liveBox.isGeometryFlipped.toggle() }
        liveBox.isHidden = false
        image.isHidden = true
        CATransaction.commit()
        needsLayout = true
        AgentCenter.shared.onEvent?("agentpane-live ctx \(made.id)")
    }

    private func removeLive() {
        guard live != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live?.layer.removeFromSuperlayer()
        live = nil
        mode = "none"
        liveBox.isHidden = true
        image.isHidden = false
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = bounds
        // The page fills the card's width, top-aligned (16:10 shows its top part).
        let f = bounds.width / max(1, pageSize.width)
        liveBox.position = .zero
        liveBox.setAffineTransform(CGAffineTransform(scaleX: f, y: f))
        CATransaction.commit()
    }
}

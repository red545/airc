// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

/// The sidebar's Agents folder (docs/user/agents.md, "Follow along"): above the tray, while an agent works in this
/// window's profile or finished in the last few minutes (Settings › Agents › "Keep finished agents for", 5 by default).
/// One row per agent tab that did something real, titled by what happened ("Gmail · read 3 pages", or the Airc Agent's
/// task) with the site's icon, and "Claude · Clicking ‘Archive’" / "Claude · Done · 3 min ago" under it; a pulsing dot
/// while the agent acts, a quiet ring while it waits; "Done" when it ends, then faded, then gone. Click a
/// row to Watch it (AgentWatchView); its menu has Take over and Stop. It folds like a folder and remembers that.
/// Private windows have their own sidebar, which never shows it. With no rows it takes no space and runs nothing.
final class SidebarAgentsView: NSView {
    static let headerHeight: CGFloat = 30
    static let rowPitch: CGFloat = 34
    static let rowHeight: CGFloat = 32
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 4
    static let expandedKey = "AgentsFolderExpanded"

    private(set) var height: CGFloat = 0
    let model = AgentsFolderModel()
    private var host: AircFirstClickHostingView<AgentsFolderContent>?
    private(set) weak var controller: WindowController?
    private var target: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    /// Watch over this window's page, while open.
    private(set) var watch: AgentWatchView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func connect(_ c: WindowController) {
        controller = c
        model.view = self
        guard host == nil else { return }
        let h = AircFirstClickHostingView(rootView: AgentsFolderContent(model: model))
        h.safeAreaRegions = []
        addSubview(h)
        host = h
        for name in [AgentActivity.changed, AgentCenter.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// The window's chrome changed (WindowController.refreshChrome: a Space switch, a theme, a shown tab).
    func chromeChanged() {
        guard let c = controller else { return }
        let theme = c.currentPalette.resolved
        if model.theme != theme { model.theme = theme }
        if let watch, watch.shownTabAtOpen != c.shownTabID { closeWatch() }   // the person picked one of their tabs
        if model.profileID != c.store.space(c.currentSpaceID)?.profileID { refresh() }
    }

    /// Rows and height from the activity model.
    func refresh() {
        guard let c = controller else { return }
        let profile = c.store.space(c.currentSpaceID)?.profileID
        model.profileID = profile
        let activity = AgentActivity.shared
        let now = Date()
        let rows = profile.map { activity.model.rows(profileID: $0) } ?? []
        let items = rows.map { r in AgentsFolderModel.Item(row: r, state: activity.model.state(r, now: now),
                                                           stopped: r.clientKey.map(AgentCenter.shared.isStopped) ?? false) }
        if items != model.items { model.items = items }
        if model.watchingID != watch?.rowID { model.watchingID = watch?.rowID }
        if let watch, let row = activity.model.row(watch.rowID) { watch.update(row: row, state: activity.model.state(row, now: now)) }
        layoutHeight()
    }

    func setExpanded(_ on: Bool) {
        model.expanded = on
        UserDefaults.standard.set(on, forKey: Self.expandedKey)
        layoutHeight()
    }

    private func layoutHeight() {
        let n = model.items.count
        let h: CGFloat = n == 0 ? 0 : Self.topInset + Self.headerHeight + (model.expanded ? CGFloat(n) * Self.rowPitch : 0) + Self.bottomInset
        guard h != target else { return }
        target = h
        guard let c = controller, window != nil, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return setHeight(h) }
        c.animator.spring("agents-folder", from: Double(height), to: Double(h), velocity: 0, spring: Spring(AircSpring.row),
                          update: { [weak self] v in self?.setHeight(CGFloat(v)) }, completion: { [weak self] in self?.setHeight(h) })
    }

    private func setHeight(_ h: CGFloat) {
        height = max(0, h)
        needsLayout = true
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        // Laid out at full height from the top, shown as the section opens over it.
        host?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(target, bounds.height))
    }

    // MARK: Watch, Take over, Stop

    func openWatch(_ rowID: String, takeKeys: Bool = true) {
        guard let c = controller, let row = AgentActivity.shared.model.row(rowID), row.isLive else { return }
        if watch?.rowID == rowID { return }
        closeWatch()
        let v = AgentWatchView(rowID: rowID, controller: c)
        watch = v
        v.start(takeKeys: takeKeys)
        if !model.expanded { setExpanded(true) }
        refresh()
    }

    // MARK: The pane task's approval, on its row (agentux, docs/design/agent-ux.md §6)

    private var approvalPopover: NSPopover?
    private var approvalSub: AnyCancellable?

    /// "✋ Pay on …?" with Open task / Deny / Allow once, pointing at the row. An AppKit popover on a first-click hosting
    /// view, so the first press on an inactive popover answers (SwiftUI's popover spent it on activation). It closes when
    /// the approval is answered anywhere (one answer clears all).
    func showApproval(at rowFrame: CGRect, open: @escaping () -> Void) {
        guard approvalPopover?.isShown != true, let host, window != nil, rowFrame.height > 0, let a = AgentRunCenter.shared.approval else { return }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
        let v = AircFirstClickHostingView(rootView: AgentRowApproval(request: a, open: { [weak self] in self?.closeApproval(); open() },
                                                                    close: { [weak self] in self?.closeApproval() }).testAnchorRoot())
        v.frame.size = v.fittingSize
        let vc = NSViewController()
        vc.view = v
        p.contentViewController = vc
        p.contentSize = v.fittingSize
        approvalPopover = p
        p.show(relativeTo: rowFrame, of: host, preferredEdge: controller?.sidebarOnRight == true ? .minX : .maxX)
        approvalSub = AgentRunCenter.shared.$approval.dropFirst().sink { [weak self] new in if new?.id != a.id { self?.closeApproval() } }
    }

    func closeApproval() {
        approvalSub = nil
        approvalPopover?.close()
        approvalPopover = nil
    }

    #if AIRC_TESTING
    var approvalPopoverView: NSView? { approvalPopover?.isShown == true ? approvalPopover?.contentViewController?.view : nil }
    #endif

    func closeWatch() {
        guard let w = watch else { return }
        watch = nil
        w.stop()
        refresh()
    }

    /// Take over: the page becomes this window's tab. Shows why not in a toast when it can't.
    func takeOver(_ rowID: String) {
        guard let c = controller, let row = AgentActivity.shared.model.row(rowID), row.isLive else { return }
        if watch?.rowID == rowID { closeWatch() }
        if let why = AgentCenter.shared.takeOver(window: row.window, tab: row.tab, into: c) { c.showToast(why) }
    }

    func stop(_ rowID: String) {
        guard let row = AgentActivity.shared.model.row(rowID) else { return }
        if watch?.rowID == rowID { closeWatch() }
        if let key = row.clientKey { AgentCenter.shared.stopClient(key) }
        else { AgentCenter.shared.closeSessionWindows(row.sessionKey) }
    }

    func allowAgain(_ rowID: String) {
        guard let key = AgentActivity.shared.model.row(rowID)?.clientKey else { return }
        AgentCenter.shared.allowAgain(key)
        refresh()
    }

    func icon(_ item: AgentsFolderModel.Item) -> NSImage? {
        AgentCenter.shared.windows[item.window]?.tab(item.tab)?.favicon
    }
}

extension AgentCenter {
    /// Stop for a connection without an app identity (test transports): its windows close.
    func closeSessionWindows(_ ownerKey: String) {
        for w in windows.values where w.ownerKey == ownerKey { closeWindow(w, end: .stopped) }
        AgentActivity.shared.sessionEnded(ownerKey, .stopped)
    }
}

final class AgentsFolderModel: ObservableObject {
    struct Item: Equatable, Identifiable {
        let id: String
        /// "Claude · Gmail" (Watch, the demos).
        let label: String
        /// What happened: "Gmail · read 3 pages", or the Airc Agent's task.
        let title: String
        let client: String
        let clientKey: String?
        let window: Int
        let tab: Int
        let live: Bool
        let acting: Bool
        let status: String
        let faded: Bool
        let stopped: Bool

        init(row r: AgentTabRow, state: AgentRowState, stopped: Bool) {
            id = r.id; label = r.label; title = r.rowTitle; client = r.client; clientKey = r.clientKey; window = r.window; tab = r.tab; live = r.isLive
            self.stopped = stopped
            switch state {
            case .acting(let caption): acting = true; faded = false; status = caption ?? "Working"
            case .idle: acting = false; faded = false; status = "Waiting"
            case .needsYou(let why): acting = false; faded = false; status = "Needs you · " + why
            case .justEnded(let end): acting = false; faded = false; status = Item.words(end)
            case .faded(let end, let minutes): acting = false; faded = true; status = Item.words(end) + " · \(minutes) min ago"
            }
        }

        /// The line under the title: the app (and its device), then what it does now or how it ended.
        var subtitle: String { client + " · " + status }

        static func words(_ end: AgentTabRow.End) -> String {
            switch end { case .done: return "Done"; case .stopped: return "Stopped"; case .takenOver: return "Yours now" }
        }
    }

    @Published var items: [Item] = []
    @Published var expanded = UserDefaults.standard.object(forKey: SidebarAgentsView.expandedKey) as? Bool ?? true
    @Published var watchingID: String?
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    var profileID: String?
    weak var view: SidebarAgentsView?

    var hasEnded: Bool { items.contains { !$0.live } }
    var actingCount: Int { items.filter(\.acting).count }
}

struct AgentsFolderContent: View {
    static let space = "agentsFolder"
    @ObservedObject var model: AgentsFolderModel
    @State private var headerHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.expanded {
                VStack(spacing: SidebarAgentsView.rowPitch - SidebarAgentsView.rowHeight) {
                    ForEach(model.items) { item in
                        AgentFolderRow(item: item, model: model, watching: model.watchingID == item.id)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SidebarAgentsView.topInset)
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.space)
        .animation(AircSpring.row.animation, value: model.items.map(\.id))
        .testAnchorRoot()
        .aircTheme(model.theme)
    }

    private var header: some View {
        AgentsFolderHeader(model: model, hovered: $headerHovered)
            .frame(height: SidebarAgentsView.headerHeight)
            .testAnchor("agents-header")
    }
}

private struct AgentsFolderHeader: View {
    @ObservedObject var model: AgentsFolderModel
    @Binding var hovered: Bool
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(model.expanded ? 90 : 0))
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: 12)
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary.color)
            Text("Agents")
                .aircFont(AircFont.callout.weight(.semibold))
                .foregroundStyle(theme.textSecondary.color)
            if AgentActivity.shared.model.needsYouCount > 0 {
                // An agent's page waits for the person (a sign-in, a captcha): AgentNeedsYou.swift.
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("An agent needs you")
                    .testAnchor("agents-needs-you")
            }
            if !model.expanded, model.actingCount > 0 {
                AgentPulseDot(acting: true, color: theme.accent.nsColor, reduceMotion: reduceMotion)
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 4)
            if model.hasEnded, hovered || !model.items.contains(where: \.live) {
                Button("Clear") { AgentActivity.shared.clearEnded() }
                    .buttonStyle(.plain)
                    .aircFont(AircFont.caption)
                    .foregroundStyle(theme.textTertiary.color)
                    .accessibilityLabel("Clear finished agent tabs")
                    .testAnchor("agents-clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous)
            .fill(hovered ? theme.hoverFill.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { withAnimation(reduceMotion ? nil : AircSpring.row.animation) { model.view?.setExpanded(!model.expanded) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents, \(model.items.count) tab\(model.items.count == 1 ? "" : "s")")
        .accessibilityValue(model.expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.view?.setExpanded(!model.expanded) }
    }
}

private struct AgentFolderRow: View {
    let item: AgentsFolderModel.Item
    @ObservedObject var model: AgentsFolderModel
    let watching: Bool
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // agentux: the pane's own task (docs/design/agent-ux.md §7): it opens in the pane, and a waiting approval shows on
    // the row (✋, "Waiting for your OK") and as a popover when the pane isn't showing the task.
    @ObservedObject private var run = AgentRunCenter.shared

    private var paneTask: Bool { AgentUI.usesPane && item.live && run.runWindowID == item.window && (item.client == AgentBridge.clientName || item.clientKey == "airc-panel") }
    private var waiting: Bool { paneTask && run.approval != nil }
    private var paneShown: Bool { model.view?.controller.flatMap { AgentPaneController.pane(of: $0) }?.isShown == true }

    private func open() {
        if paneTask, let c = model.view?.controller { AgentPaneController.show(c) } else if item.live { model.view?.openWatch(item.id) }
    }

    @State private var frameInFolder: CGRect = .zero

    var body: some View {
        row
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frameInFolder = g.frame(in: .named(AgentsFolderContent.space)) }
                    .onChange(of: g.frame(in: .named(AgentsFolderContent.space))) { _, f in frameInFolder = f }
            })
            .onChange(of: run.approval) { _, a in
                if a != nil, waiting, !paneShown { model.view?.showApproval(at: frameInFolder, open: { open() }) }
            }
            .onAppear { if waiting && !paneShown { model.view?.showApproval(at: frameInFolder, open: { open() }) } }
    }

    private var row: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .testAnchor("agents-title-\(item.id)")
                // The app, then its state: a long device name gives way before "Done · 3 min ago" does.
                HStack(spacing: 0) {
                    Text(item.client).lineLimit(1).truncationMode(.middle)
                    Text(" · " + (waiting ? "Waiting for your OK" : item.status)).lineLimit(1).layoutPriority(1)
                }
                .aircFont(AircFont.caption)
                .foregroundStyle(theme.textTertiary.color)
            }
            Spacer(minLength: 2)
            if waiting, !hovered {
                Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(.orange).padding(.trailing, 2)
                    .accessibilityLabel("Waiting for your OK")
                    .testAnchor("agents-waiting-\(item.id)")
            } else if hovered, item.live {
                // agentux: Watch is one click on any working row (a background agent's page is off screen otherwise).
                TrayButton(symbol: "eye", help: "Watch the agent's page") { model.view?.openWatch(item.id) }
                    .accessibilityLabel("Watch \(item.client)")
                    .testAnchor("agents-watch-\(item.id)")
                TrayButton(symbol: "stop.fill", help: "Stop \(item.client)") { model.view?.stop(item.id) }
                    .accessibilityLabel("Stop \(item.client)")
                    .testAnchor("agents-stop-\(item.id)")
            } else if item.live {
                AgentPulseDot(acting: item.acting, color: theme.accent.nsColor, reduceMotion: reduceMotion)
                    .frame(width: 8, height: 8)
                    .padding(.trailing, 4)
                    .testAnchor("agents-dot-\(item.id)")
            }
        }
        .padding(.leading, AircMetrics.Row.folderIndent)
        .padding(.trailing, 6)
        .frame(height: SidebarAgentsView.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircMetrics.Row.plateRadius, style: .continuous)
            .fill((watching ? theme.selectedFill : hovered ? theme.hoverFill : AircColor.clear).color))
        .opacity(item.faded ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open() }
        .contextMenu { menu }
        .testAnchor("agents-row-\(item.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.client + ", " + (item.live ? (item.acting ? "Working: \(item.status)" : "Waiting") : item.status))
        .accessibilityHint(paneTask ? "Open the task in the agent pane" : item.live ? "Watch what the agent does" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if item.live { model.view?.openWatch(item.id) } }
        .accessibilityAction(named: "Watch") { model.view?.openWatch(item.id) }
        .accessibilityAction(named: "Take over") { model.view?.takeOver(item.id) }
        .accessibilityAction(named: "Stop \(item.client)") { model.view?.stop(item.id) }
    }

    @ViewBuilder private var icon: some View {
        if let image = model.view?.icon(item) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(theme.textSecondary.color).frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var menu: some View {
        if item.live {
            Button("Watch") { model.view?.openWatch(item.id) }
            Button("Take Over") { model.view?.takeOver(item.id) }
            Divider()
            Button("Stop \(item.client)") { model.view?.stop(item.id) }
        } else if item.stopped {
            Button("Allow \(item.client) Again") { model.view?.allowAgain(item.id) }
        }
        if !item.live { Button("Clear Finished") { AgentActivity.shared.clearEnded() } }
    }
}

/// The acting dot: a soft pulse on Core Animation (the render server runs it; the app does nothing per frame), a solid
/// dot under Reduce Motion, a quiet ring while the agent waits.
struct AgentPulseDot: NSViewRepresentable {
    let acting: Bool
    let color: NSColor
    let reduceMotion: Bool

    final class DotView: NSView {
        let dot = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
        }
        /// Whether the pulse runs (checks read it).
        var pulsing: Bool { dot.animation(forKey: "pulse") != nil }
    }

    func makeNSView(context: Context) -> DotView { DotView(frame: .zero) }

    func updateNSView(_ v: DotView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if acting {
            v.dot.backgroundColor = color.cgColor
            v.dot.borderWidth = 0
        } else {
            v.dot.backgroundColor = NSColor.clear.cgColor
            v.dot.borderColor = color.withAlphaComponent(0.55).cgColor
            v.dot.borderWidth = 1.5
        }
        CATransaction.commit()
        let pulse = acting && !reduceMotion
        if pulse, v.dot.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 0.7
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.dot.add(a, forKey: "pulse")
            AgentPulseDot.pulsing.insert(ObjectIdentifier(v))
        } else if !pulse, v.dot.animation(forKey: "pulse") != nil {
            v.dot.removeAnimation(forKey: "pulse")
            AgentPulseDot.pulsing.remove(ObjectIdentifier(v))
        }
    }

    static func dismantleNSView(_ v: DotView, coordinator: ()) { pulsing.remove(ObjectIdentifier(v)) }

    /// The dots pulsing now (checks count them).
    static var pulsing: Set<ObjectIdentifier> = []
}

/// The popover's content: what the agent wants to do, and the three answers. Nothing is pre-selected.
private struct AgentRowApproval: View {
    let request: AgentApprovalRequest
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).aircFont(AircFont.body.weight(.semibold))
            }
            Text(request.risk.reason).aircFont(AircFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Open task", action: open).buttonStyle(.airc(.secondary, size: .small)).testAnchor("agents-popover-open")
                Spacer()
                Button("Deny") { close(); AgentRunCenter.shared.answerApproval(allow: false) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agents-popover-deny")
                Button("Allow once") { close(); AgentRunCenter.shared.answerApproval(allow: true) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agents-popover-allow")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

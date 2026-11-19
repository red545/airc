// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AppKit
import SwiftUI

/// "✦ Claude is using Airc": an app outside Airc (Claude Desktop, Claude Code, Cursor …) is working in Airc right now. A
/// row of the sidebar right under its header (the traffic lights' row), like Chrome's "controlled by automated software"
/// bar: next to the traffic lights, never over them. Click: what it means, Watch, Stop.
/// Shown while that app has agent windows open; the Airc Agent's own run isn't counted (its pane shows it).
final class AgentControlPill: NSView {
    struct App: Equatable {
        let key: String
        let clientKey: String?
        let ownerKey: String
        let name: String
        let profileID: String
    }

    weak var controller: WindowController?
    private(set) var apps: [App] = []
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var fill: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }
    var hoverFill: NSColor = .tertiaryLabelColor
    var theme: ResolvedTheme?
    private var hovering = false { didSet { needsDisplay = true } }
    private var popover: NSPopover?
    private var sub: NSObjectProtocol?
    /// Narrow header: only the ✦.
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        sub = NotificationCenter.default.addObserver(forName: AgentCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let sub { NotificationCenter.default.removeObserver(sub) } }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Outside apps with agent windows now, in the order their first window opened.
    static func current() -> [App] {
        var seen = Set<String>()
        var out: [App] = []
        for w in AgentCenter.shared.windows.values.sorted(by: { $0.id < $1.id }) where w.clientKey != AgentBridge.clientKey {
            let key = w.clientKey ?? w.ownerKey
            guard seen.insert(key).inserted else { continue }
            out.append(App(key: key, clientKey: w.clientKey, ownerKey: w.ownerKey, name: w.clientName ?? w.client, profileID: w.profileID))
        }
        return out
    }

    var label: String {
        guard let first = apps.first else { return "" }
        return apps.count == 1 ? first.name : "\(first.name) +\(apps.count - 1)"
    }

    /// "Claude is using Airc" (VoiceOver, tooltip, checks).
    var sentence: String {
        apps.isEmpty ? "" : (apps.count == 1 ? "\(apps[0].name) is using Airc" : "\(apps.map(\.name).joined(separator: ", ")) are using Airc")
    }

    func refresh() {
        let now = Self.current()
        guard now != apps || isHidden != now.isEmpty else { return }
        apps = now
        isHidden = now.isEmpty
        if now.isEmpty { popover?.close() }
        toolTip = now.isEmpty ? nil : sentence + ". Click for what it can do, Watch and Stop."
        setAccessibilityLabel(sentence)
        needsDisplay = true
        superview?.needsLayout = true
    }

    private var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    private static let mark = "✦"

    /// Its width for `label` (the ✦ alone when compact).
    func preferredWidth(compact c: Bool) -> CGFloat {
        let markW = (Self.mark as NSString).size(withAttributes: [.font: font]).width
        if c { return ceil(markW) + 14 }
        let textW = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(markW + 4 + textW) + 16
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (hovering ? hoverFill : fill).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let markAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlAccentColor]
        let s = NSMutableAttributedString(string: Self.mark, attributes: markAttrs)
        if !compact { s.append(NSAttributedString(string: " " + sentence, attributes: attrs)) }
        // "›": it opens something.
        let chevron = NSAttributedString(string: "›", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: tint])
        let cs = chevron.size()
        if !compact, bounds.width > 60 { chevron.draw(at: NSPoint(x: bounds.width - 10 - cs.width, y: (bounds.height - cs.height) / 2)) }
        let size = s.size()
        var rect = NSRect(x: 9, y: (bounds.height - size.height) / 2, width: bounds.width - 30, height: size.height)
        if compact { rect.origin.x = (bounds.width - size.width) / 2; rect.size.width = size.width }
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }
    override func accessibilityPerformPress() -> Bool { open(); return true }

    /// The explanation, with Watch and Stop.
    var popoverView: NSView? { popover?.isShown == true ? popover?.contentViewController?.view : nil }

    func open() {
        guard !apps.isEmpty, window != nil else { return }
        if popover?.isShown == true { popover?.close(); return }
        let names = Dictionary((controller?.store.orderedProfiles ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let content = AgentControlPopover(apps: apps, profileNames: names,
                                          watch: { [weak self] in self?.watch() },
                                          stop: { [weak self] in self?.stop() },
                                          settings: { [weak self] in
                                              self?.popover?.close()
                                              (NSApp.delegate as? AppDelegate)?.showSettings(page: .agents)
                                          })
        let root: AnyView = theme.map { AnyView(content.environment(\.aircTheme, $0)) } ?? AnyView(content)
        let v = AircFirstClickHostingView(rootView: root.testAnchorRoot())
        v.frame.size = v.fittingSize
        let vc = NSViewController()
        vc.view = v
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let t = theme { p.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua) }
        p.contentViewController = vc
        p.contentSize = v.fittingSize
        popover = p
        p.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        AgentCenter.shared.onEvent?("control-pill open \(apps.map(\.name).joined(separator: ","))")
    }

    /// Watch: the first live page of the first app, in this window.
    func watch() {
        popover?.close()
        let keys = Set(apps.map(\.ownerKey))
        guard let c = controller, let row = AgentActivity.shared.model.rows.first(where: { $0.isLive && keys.contains($0.sessionKey) }) else { return }
        c.sidebar.agents.openWatch(row.id)
    }

    /// Stop: every outside app working now (the same Stop as its row in the Agents folder).
    func stop() {
        popover?.close()
        for a in apps {
            if let k = a.clientKey { AgentCenter.shared.stopClient(k) } else { AgentCenter.shared.closeSessionWindows(a.ownerKey) }
        }
        AgentCenter.shared.onEvent?("control-pill stop")
        refresh()
    }
}

/// The pill's popover: what is happening, in plain words, and what the person can do.
struct AgentControlPopover: View {
    let apps: [AgentControlPill.App]
    let profileNames: [String: String]
    let watch: () -> Void
    let stop: () -> Void
    let settings: () -> Void
    @Environment(\.aircTheme) private var theme

    private var who: String { apps.count == 1 ? apps[0].name : apps.map(\.name).joined(separator: ", ") }
    private var profiles: String {
        let names = Array(Set(apps.compactMap { profileNames[$0.profileID] })).sorted()
        return names.isEmpty ? "" : " in your profile " + names.map { "“\($0)”" }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("✦").foregroundStyle(Color.accentColor)
                Text("\(who) \(apps.count == 1 ? "is" : "are") using Airc").aircFont(AircFont.body).fontWeight(.semibold)
                    .foregroundStyle(theme.surfaceText.color).testAnchor("agentpill.title")
            }
            Text("You asked \(apps.count == 1 ? "it" : "them") to browse for you. \(apps.count == 1 ? "It works" : "They work") in \(apps.count == 1 ? "its" : "their") own windows\(profiles), which stay hidden and never take your keyboard or mouse. Your windows and tabs aren't touched.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            Text("Watch shows what it's doing. Stop ends it now and keeps it out until you allow it again in Settings › Agents.")
                .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Settings…", action: settings).buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpill.settings")
                Spacer(minLength: 8)
                Button("Watch", action: watch).buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpill.watch")
                Button("Stop", action: stop).buttonStyle(.airc(.primary, size: .small)).testAnchor("agentpill.stop")
            }
        }
        .padding(14)
        .frame(width: 300)
        .testAnchor("agentpill.popover")
    }
}

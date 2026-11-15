// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AppKit
import SwiftUI

enum AgentDecision { case allow, deny, noAnswer }

/// The one-time question for an app Airc hasn't seen: "Allow ‘Claude’ to use Airc?" (docs/user/agents.md). One panel
/// per app, however many connections it opens meanwhile; the answer is remembered per app (AgentCenter).
///
/// It never takes the person's focus: a non-activating panel. With Airc frontmost it sits over Airc's window; otherwise
/// it shows like a notification, in the top-right corner of the screen the person is using, and Airc stays in the
/// background. Unanswered for two minutes, it goes away and the connection is refused (nothing remembered).
final class AgentApprovals {
    /// Test builds: answer without asking (`--agent-approve=allow|deny`). nil asks.
    var automatic: Bool?
    var timeout: TimeInterval = 120
    private struct Pending {
        let identity: AgentClientIdentity
        let panel: AgentApprovalPanel
        var waiters: [(AgentDecision) -> Void]
    }
    private var pending: [String: Pending] = [:]

    /// The panel on screen (checks press its buttons through `answer`).
    var shown: AgentApprovalPanel? { pending.values.first?.panel }
    var waitingCount: Int { pending.count }

    func ask(_ identity: AgentClientIdentity, profiles: [String], _ done: @escaping (AgentDecision) -> Void) {
        if let automatic { return done(automatic ? .allow : .deny) }
        if pending[identity.key] != nil {
            pending[identity.key]?.waiters.append(done)
            return
        }
        let panel = AgentApprovalPanel(identity: identity, profiles: profiles) { [weak self] decision in
            self?.finish(identity.key, decision)
        }
        pending[identity.key] = Pending(identity: identity, panel: panel, waiters: [done])
        panel.present(stackIndex: pending.count - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak panel] in
            guard let self, let panel, self.pending[identity.key]?.panel === panel else { return }
            self.finish(identity.key, .noAnswer)
        }
    }

    private func finish(_ key: String, _ decision: AgentDecision) {
        guard let p = pending.removeValue(forKey: key) else { return }
        p.panel.dismiss()
        for w in p.waiters { w(decision) }
    }

    /// Stop Agents and Off: every question goes away unanswered.
    func cancelAll() {
        for key in Array(pending.keys) { finish(key, .noAnswer) }
    }
}

/// The question's window: a small floating card, never key unless the person clicks into it, never activating Airc.
final class AgentApprovalPanel: NSPanel {
    let identity: AgentClientIdentity
    let profiles: [String]
    private let decide: (AgentDecision) -> Void
    private var decided = false

    static let width: CGFloat = 380

    init(identity: AgentClientIdentity, profiles: [String], decide: @escaping (AgentDecision) -> Void) {
        self.identity = identity
        self.profiles = profiles
        self.decide = decide
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 180),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .utilityWindow
        title = "Allow \(identity.displayName) to use Airc?"
        let automated = (NSApp.delegate as? AppDelegate)?.options.isAutomated == true
        if !automated {
            // Like a notification: over other apps' windows on the Space in use, Airc staying in the background.
            level = .floating
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }
        let card = AgentApprovalCard(name: identity.displayName, profiles: profiles, detail: identity.detail,
                                     icon: Self.icon(for: identity)) { [weak self] allow in self?.answer(allow ? .allow : .deny) }
        let host = onMain { FirstClickHostingView(rootView: card) }
        host.frame.size = host.fittingSize
        contentView = host
        setContentSize(NSSize(width: Self.width, height: host.fittingSize.height))
    }

    /// The buttons' action (checks call it too, as the buttons do).
    func answer(_ decision: AgentDecision) {
        guard !decided else { return }
        decided = true
        decide(decision)
    }

    override var canBecomeMain: Bool { false }

    func present(stackIndex: Int) {
        let size = frame.size
        if NSApp.isActive, let anchor = NSApp.keyWindow ?? NSApp.mainWindow, anchor.isVisible, !(anchor is AgentHostWindow) {
            // Over Airc's own window: centred, a third of the way down.
            let f = anchor.frame
            setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: (f.maxY - f.height / 3 - size.height / 2).rounded()))
        } else {
            // A notification's place: the top-right corner of the screen in use (the menu bar's), stacked.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
            let v = screen.visibleFrame
            setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16 - CGFloat(stackIndex) * (size.height + 10)))
        }
        if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true {
            orderFront(nil)
        } else {
            orderFrontRegardless()   // a non-activating panel: shown without making Airc the active app
        }
    }

    func dismiss() {
        orderOut(nil)
        close()
    }

    static func icon(for identity: AgentClientIdentity) -> NSImage {
        // Another device of the tailnet: a laptop drawn in the text colour (a bare template symbol reads as a dark block).
        let tint = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular).applying(.init(hierarchicalColor: .labelColor))
        if identity.kind == .remote,
           let device = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Another device")?.withSymbolConfiguration(tint) {
            return device
        }
        if let pid = identity.pid, let path = AgentClientIdentity.path(of: pid), let r = path.range(of: ".app/") {
            return NSWorkspace.shared.icon(forFile: String(path[..<r.lowerBound]) + ".app")
        }
        if let pid = identity.pid, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon { return icon }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    /// The panel's picture, for the checks' screenshots (its own drawing, no Screen Recording).
    func picture() -> NSBitmapImageRep? {
        guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// The card's buttons answer the first click, with Airc in the background (the panel never becomes key first).
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// "Allow ‘Claude’ to use Airc?" in Airc's design: the app's icon, the question, what it means, who signed it.
private struct AgentApprovalCard: View {
    let name: String
    let profiles: [String]
    let detail: String
    let icon: NSImage
    let answer: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    private var theme: ResolvedTheme { DesignTheme.default.resolved(systemIsDark: scheme == .dark) }

    private var profileText: String {
        switch profiles.count {
        case 0: return "your profiles"
        case 1: return profiles[0]
        default: return profiles.dropLast().joined(separator: ", ") + " and " + profiles.last!
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                    Image(nsImage: AppIconImage.image).resizable().interpolation(.high).frame(width: 18, height: 18)
                        .offset(x: 5, y: 5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow ‘\(name)’ to use Airc?").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It can open pages and act in your signed-in sites in \(profileText). It never sees your saved passwords or your private windows.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                        .lineLimit(2).truncationMode(.middle).padding(.top, 2)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Don't Allow") { answer(false) }.buttonStyle(.airc(.secondary))
                    .accessibilityIdentifier("agent-approval-deny")
                Button("Allow") { answer(true) }.buttonStyle(.airc(.primary))
                    .accessibilityIdentifier("agent-approval-allow")
                    .testAnchor("agent-approval-allow")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: AgentApprovalPanel.width, alignment: .leading)
        .background(theme.surface.color)
        .aircTheme(theme)
    }
}

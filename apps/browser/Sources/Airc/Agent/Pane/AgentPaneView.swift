// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// The pane's SwiftUI content (docs/design/agent-ux.md §3, mockups M1–M3): header, live page card, transcript with the
/// step rail, the approval pinned above the composer, and the composer.
struct AgentPaneRoot: View {
    @ObservedObject var model: AgentPaneModel
    @Environment(\.aircTheme) private var envTheme

    var body: some View {
        if let t = model.theme { AgentPaneView(model: model).environment(\.aircTheme, t) } else { AgentPaneView(model: model) }
    }
}

struct AgentPaneView: View {
    @ObservedObject var model: AgentPaneModel
    @ObservedObject private var run = AgentRunCenter.shared
    @ObservedObject private var timeline = AgentPaneTimeline.shared
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            switch model.mode {
            case .connect: ScrollView { connect.padding(16) }.frame(maxHeight: .infinity)
            case .newTask: ScrollView { newTask.padding(16) }.frame(maxHeight: .infinity)
            case .conversation: conversation
            }
            if let a = run.approval { AgentPaneApproval(request: a).padding(.horizontal, 12).padding(.bottom, 8).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if let t = model.takenOver { takenOverBanner(t).padding(.horizontal, 12).padding(.bottom, 8) }
            AgentPaneComposer(model: model)
        }
        .background(theme.surface.color)
        .animation(.easeOut(duration: 0.18), value: run.approval)
        .testAnchor("agentpane")
        .testAnchorRoot()
    }

    // MARK: Header (44 pt)

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.title).aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
                .lineLimit(1).truncationMode(.tail).testAnchor("agentpane.title")
            Spacer(minLength: 8)
            iconButton("clock.arrow.circlepath", "All tasks", anchor: "agentpane.history") { model.openAllTasks() }
            iconButton("square.and.pencil", "New task (⇧⌥⌘A)", anchor: "agentpane.new") { model.newTask() }
                .disabled(run.steps.isEmpty && !run.state.isActive)
            iconButton("xmark", "Close (⌥⌘A)", anchor: "agentpane.close") { model.pane?.close() }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 44)
    }

    private func iconButton(_ symbol: String, _ help: String, anchor: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.surfaceTextSecondary.color)
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(anchor)
    }

    // MARK: Empty states

    private var newTask: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 40)
            mark
            Text("What should Airc do?").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Text("It works in your signed-in sites, in the background. It asks before paying, sending, posting or deleting.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            VStack(spacing: 6) {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { n, s in
                    Button { model.text = s; model.pane?.focus() } label: {
                        Text(s).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.surfaceBorder.color))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .testAnchor("agentpane.suggestion.\(n)")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .testAnchor("agentpane.newtask")
    }

    private var mark: some View {
        Image(systemName: "sparkles").font(.system(size: 18, weight: .medium)).foregroundStyle(theme.accent.color)
            .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10).fill(theme.tileFill.color))
    }

    private var connect: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 30)
            mark
            Text("Connect your AI").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Text("Use a plan you already pay for, or your own API key. Airc never sees your sign-in.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(model.providers) { p in AgentPaneProviderRow(provider: p, model: model) }
            }
            .padding(.top, 6)
            Text("Claude Code and Codex run on this Mac with your own sign-in. Airc gives them only its browser tools; your tasks and the pages they read go to that provider under your plan's terms.")
                .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .testAnchor("agentpane.connect")
    }

    // MARK: The conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            // The live page stays put above the transcript (it scrolled away under new steps, and under a click).
            if run.state.isActive || run.approval != nil, model.takenOver == nil, run.runWindowID != nil {
                AgentPaneLiveCard(model: model).padding(.horizontal, 14).padding(.top, 10)
            }
            // An error stays at the top with its way out (it scrolled off under a click with the transcript).
            if let p = model.problem { problem(p).padding(.horizontal, 14).padding(.top, 10) }
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { item in AgentPaneItemView(item: item, model: model).id(item.id) }
                    if !run.partial.isEmpty {
                        Text(run.partial).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                            .fixedSize(horizontal: false, vertical: true).id("partial").testAnchor("agentpane.partial")
                    } else if run.state == .running, !model.lastItemIsSteps {
                        AgentPaneThinking().id("thinking")
                    }
                    if !run.state.isActive, run.steps.contains(where: { $0.kind == .final }) { footerActions.id("footer") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: run.steps.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
            .onChange(of: run.partial.count / 80) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: run.state) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
        }
        .frame(maxHeight: .infinity)
    }

    private func problem(_ p: AgentPaneModel.Problem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.message).aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
                .fixedSize(horizontal: false, vertical: true).testAnchor("agentpane.error.text")
            if let d = p.detail {
                Text(d).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                let others = model.providers.filter { $0.ready && !$0.selected }
                if p.retry, let other = others.first {
                    Button("Use \(other.name.replacingOccurrences(of: " API key", with: "")) instead") { model.switchProvider(other, retrying: true) }
                        .buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpane.error.switch")
                }
                if p.settings {
                    Button("Open Settings") { model.providers.first?.setUp() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpane.error.settings")
                }
                if p.continues {
                    Button("Continue") { run.continueRun() }.buttonStyle(.airc(.primary, size: .small)).testAnchor("agentpane.continue")
                }
                if p.retry {
                    Button("Try again") { model.retry() }.buttonStyle(.airc(.primary, size: .small)).testAnchor("agentpane.error.retry")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.55)))
        .testAnchor("agentpane.error")
    }

    private var footerActions: some View {
        HStack(spacing: 6) {
            Button("Copy") { model.copyAnswer() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpane.copy")
            Spacer()
            Text(run.usageLine).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
        }
    }

    private func takenOverBanner(_ t: AgentPaneModel.TakenOver) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You have the page.").aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
            Text("The agent is paused while you use “\(t.title)” in this window. Hand it back to let the agent go on from where you left it.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Stop task") { model.stopTask() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentpane.takenover.stop")
                Button("Hand back") { model.handBack() }.buttonStyle(.airc(.primary, size: .small)).testAnchor("agentpane.handback")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tileFill.color))
        .testAnchor("agentpane.takenover")
    }
}

// MARK: Transcript items

struct AgentPaneItemView: View {
    let item: AgentPaneItem
    @ObservedObject var model: AgentPaneModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        switch item {
        case .prompt(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.selectedFill.color))
            }
            .testAnchor("agentpane.prompt")
        case .text(_, let text, let final):
            AgentPaneMarkdown(text: text).testAnchor(final ? "agentpane.answer" : "agentpane.say")
        case .steps(_, let rows, let running):
            AgentPaneStepRail(rows: rows, runningLast: running && AgentRunCenter.shared.state == .running)
                .testAnchor("agentpane.steps")
        case .summary(let id, let line, let rows):
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.expanded.contains(id) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(line).aircFont(AircFont.callout)
                    }
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line + (model.expanded.contains(id) ? ", expanded" : ", collapsed"))
                .testAnchor("agentpane.summary")
                if model.expanded.contains(id) { AgentPaneStepRail(rows: rows, runningLast: false).padding(.leading, 2).testAnchor("agentpane.steps.expanded") }
            }
        case .note(_, let kind, let text, let detail):
            AgentPaneNote(kind: kind, text: text, detail: detail)
        case .memory(_, let step):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AgentPaneNote(kind: .memory, text: step.text, detail: step.detail)
                Spacer(minLength: 4)
                if step.memoryLine != nil {
                    Button("Undo") { AgentRunCenter.shared.undoMemory(step.id) }.buttonStyle(.airc(.secondary, size: .small))
                        .testAnchor("agentpane.memory.undo")
                }
            }
        case .sites(_, let sites):
            AgentPaneFlow(spacing: 6) {
                ForEach(sites, id: \.self) { s in
                    Button { model.open(s) } label: {
                        HStack(spacing: 4) {
                            AgentPaneSiteIcon(host: s.host, size: 12)
                            Text(s.host).aircFont(AircFont.callout).lineLimit(1)
                        }
                        .foregroundStyle(theme.surfaceText.color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(theme.tileFill.color))
                    }
                    .buttonStyle(.plain)
                    .help("Open \(s.host) in a new tab")
                    .testAnchor("agentpane.site.\(s.host)")
                }
            }
        }
    }
}

/// One-line steps on a 1 pt rail, each with its site's icon; the running one shimmers.
struct AgentPaneStepRail: View {
    let rows: [AgentPaneItem.StepRow]
    let runningLast: Bool
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { n, r in
                let running = runningLast && n == rows.count - 1
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        Rectangle().fill(theme.separator.color).frame(width: 1)
                            .padding(.top, n == 0 ? 11 : 0).padding(.bottom, n == rows.count - 1 ? 11 : 0)
                        AgentPaneSiteIcon(host: r.host, size: 14).background(Circle().fill(theme.surface.color).frame(width: 18, height: 18))
                    }
                    .frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        AgentPaneShimmerText(text: r.caption, on: running)
                        if let d = r.detail, !d.isEmpty {
                            Text(d).aircFont(AircFont.caption).foregroundStyle(Color.red.opacity(0.8)).lineLimit(2)
                        }
                    }
                }
                .frame(minHeight: 22)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step: \(r.caption)")
            }
        }
    }
}

/// The step's caption; the running step shimmers (Reduce Motion: a static bullet instead).
struct AgentPaneShimmerText: View {
    let text: String
    let on: Bool
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let base = Text(text).aircFont(AircFont.callout).lineLimit(1).truncationMode(.middle)
        if on && !reduceMotion {
            // The sweep runs on Core Animation (idlecpu): a SwiftUI repeatForever redrew the pane every frame while an
            // agent worked (the app's main thread at the display's rate); the render server now moves the band.
            base.foregroundStyle(theme.surfaceTextSecondary.color)
                .overlay(AgentPaneShimmerSweep(content: AnyView(base.foregroundStyle(theme.surfaceText.color.opacity(0.9)))))
                .testAnchor("agentpane.step.running")
        } else {
            base.foregroundStyle(on ? theme.surfaceText.color : theme.surfaceTextSecondary.color)
        }
    }
}

/// The bright copy of the text under a band-shaped gradient mask that slides across it, 1.4 s per sweep, linear, like
/// the earlier SwiftUI version (band half the width, from one band left of the text to half a width past it). The
/// copy is drawn once; Core Animation moves the mask, so the app does no work per frame.
struct AgentPaneShimmerSweep: NSViewRepresentable {
    let content: AnyView

    final class SweepView: NSView {
        let host: NSHostingView<AnyView>
        let band = CAGradientLayer()
        private var sweptWidth: CGFloat = -1
        init(_ content: AnyView) {
            host = NSHostingView(rootView: content)
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(host)
            band.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.mask = band
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            host.frame = bounds
            sweep()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sweptWidth = -1
            sweep()
        }
        /// (Re)starts the sweep when the width changes or the animation went away (a window move drops it).
        func sweep() {
            let w = bounds.width
            guard w > 0, window != nil else { return }
            if w == sweptWidth, band.animation(forKey: "sweep") != nil { return }
            sweptWidth = w
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.frame = CGRect(x: -w, y: 0, width: w * 0.5, height: bounds.height)
            CATransaction.commit()
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = -0.75 * w
            a.toValue = 1.75 * w
            a.duration = 1.4
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            band.add(a, forKey: "sweep")
        }
        /// Whether the sweep runs (checks read it).
        var sweeping: Bool { band.animation(forKey: "sweep") != nil }
    }

    func makeNSView(context: Context) -> SweepView { SweepView(content) }
    func updateNSView(_ v: SweepView, context: Context) { v.host.rootView = content }
}

struct AgentPaneThinking: View {
    var body: some View { AgentPaneShimmerText(text: "Thinking…", on: true).testAnchor("agentpane.thinking") }
}

/// A site's icon from the agent's pages, else a globe.
struct AgentPaneSiteIcon: View {
    let host: String?
    let size: CGFloat
    @Environment(\.aircTheme) private var theme

    var body: some View {
        if let img = AgentPaneTimeline.shared.icon(host) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.8)).foregroundStyle(theme.surfaceTextTertiary.color).frame(width: size, height: size)
        }
    }
}

struct AgentPaneNote: View {
    let kind: AgentStep.Kind
    let text: String
    let detail: String?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .testAnchor(anchor)
    }

    private var icon: String {
        switch kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .approval: return "hand.raised.fill"
        case .decision: return text.hasPrefix("Allowed") ? "checkmark.circle.fill" : "xmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .memory: return "book.closed"
        default: return "info.circle"
        }
    }

    private var tint: Color {
        switch kind {
        case .warning, .approval: return .orange
        case .error: return .red
        default: return theme.surfaceTextTertiary.color
        }
    }

    private var anchor: String {
        switch kind {
        case .warning: return "agentpane.warning"
        case .decision: return "agentpane.decision"
        case .error: return "agentpane.errorline"
        default: return "agentpane.note"
        }
    }
}

/// The agent's text: Markdown (bold, lists, links, code) as AttributedString renders it.
struct AgentPaneMarkdown: View {
    let text: String
    @Environment(\.aircTheme) private var theme

    var body: some View {
        Text(Self.attributed(text)).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).textSelection(.enabled)
            .tint(theme.accentText.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Lays chips out in rows.
struct AgentPaneFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: Providers

struct AgentPaneProviderRow: View {
    let provider: AgentPaneProvider
    @ObservedObject var model: AgentPaneModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
                Text("\(provider.subtitle) · \(provider.status)").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                    .help(provider.hint ?? "")
            }
            Spacer(minLength: 6)
            if let fix = provider.fix {
                Button(fix) { provider.setUp() }.buttonStyle(.airc(provider.group == .plan && fix != "Check" ? .primary : .secondary, size: .small)).testAnchor("agentpane.provider.\(provider.id).fix")
            } else {
                Button("Use") { model.switchProvider(provider, retrying: false) }.buttonStyle(.airc(.primary, size: .small))
                    .testAnchor("agentpane.provider.\(provider.id).use")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.surfaceBorder.color))
        .testAnchor("agentpane.provider.\(provider.id)")
    }
}

// MARK: Approval

/// Pay, send, post, delete: pinned above the composer. Nothing is pre-selected; Esc denies.
struct AgentPaneApproval: View {
    let request: AgentApprovalRequest
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
            }
            Text(request.risk.reason).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Esc denies").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                Spacer()
                Button("Deny") { AgentRunCenter.shared.answerApproval(allow: false) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agentpane.deny")
                Button("Allow once") { AgentRunCenter.shared.answerApproval(allow: true) }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("agentpane.allow")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(theme.isDark ? 0.16 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting for your OK: \(request.title)")
        .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: "Airc Agent needs your OK: \(request.title)", .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
        .testAnchor("agentpane.approval")
    }
}

// MARK: Composer

struct AgentPaneComposer: View {
    @ObservedObject var model: AgentPaneModel
    @ObservedObject private var run = AgentRunCenter.shared
    @Environment(\.aircTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.page, run.steps.isEmpty { chip(p) }
                TextField(model.placeholder, text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .aircFont(AircFont.body)
                    .lineLimit(2...8)
                    .focused($focused)
                    .onSubmit { model.send() }
                    .onKeyPress(.upArrow) {
                        guard model.text.isEmpty else { return .ignored }
                        model.recall()
                        return .handled
                    }
                    .testAnchor("agentpane.field")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? theme.focusRing.color.opacity(0.6) : theme.surfaceBorder.color))
            HStack(spacing: 6) {
                providerPill
                levelPill
                Spacer(minLength: 4)
                if let p = model.progress {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(model.progress ?? p).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).monospacedDigit()
                    }
                    .testAnchor("agentpane.progress")
                }
                sendButton
            }
            if model.armedStop {
                Text("Press Esc again to stop").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
    }

    private func chip(_ p: AgentPaneModel.PageChip) -> some View {
        HStack(spacing: 4) {
            AgentPaneSiteIcon(host: p.url.host, size: 12)
            Text("\(p.title) · \(p.url.host.map(AgentPaneTimeline.trimmed) ?? "")").aircFont(AircFont.caption).lineLimit(1).truncationMode(.middle)
            Button { model.removeChip() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).help("Don't attach this page").testAnchor("agentpane.chip.remove")
        }
        .foregroundStyle(theme.surfaceTextSecondary.color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.tileFill.color))
        .frame(maxWidth: 300, alignment: .leading)
        .testAnchor("agentpane.chip")
    }

    private var providerPill: some View {
        Menu {
            Section("Your plans") {
                ForEach(model.providers.filter { $0.group == .plan }) { p in
                    Button {
                        if p.ready { model.switchProvider(p, retrying: false) } else { p.setUp() }
                    } label: {
                        Text(p.selected ? "✓ \(p.name)" : p.name) + Text(p.ready ? "  \(p.subtitle)" : "  \(p.fix ?? "")")
                    }
                }
            }
            Section("API keys") {
                ForEach(model.providers.filter { $0.group == .key }) { p in
                    Button {
                        if p.ready { model.switchProvider(p, retrying: false) } else { p.setUp() }
                    } label: {
                        Text(p.selected ? "✓ \(p.name)" : p.name) + Text(p.ready ? "  \(p.status)" : "  \(p.fix ?? "")")
                    }
                }
            }
            Divider()
            Button("Manage in Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai) }
        } label: {
            Text(model.providerLabel).aircFont(AircFont.caption).lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().strokeBorder(theme.surfaceBorder.color))
        .disabled(run.state.isActive)
        .help("Who runs the agent")
        .testAnchor("agentpane.provider")
    }

    private var levelPill: some View {
        Menu {
            ForEach(AgentLevel.allCases, id: \.self) { l in
                Button(l == run.level ? "✓ \(l.name)" : l.name) { run.level = l }
            }
        } label: {
            Text(run.level.name).aircFont(AircFont.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().strokeBorder(theme.surfaceBorder.color))
        .disabled(run.state.isActive)
        .help("Quick: up to 25 steps and 3 minutes. Keep going: up to 200 steps and 30 minutes.")
        .testAnchor("agentpane.level")
    }

    @ViewBuilder private var sendButton: some View {
        if run.state.isActive && run.approval == nil {
            Button { model.stop() } label: {
                // The glyph in the surface colour on a text-coloured circle: dark on light, light on dark (onAccent was white on
                // white in dark Spaces).
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.surface.color)
                    .frame(width: 28, height: 28).background(Circle().fill(theme.surfaceText.color))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop (⌘.)")
            .accessibilityLabel("Stop")
            .testAnchor("agentpane.stop")
        } else {
            let empty = model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { model.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.onAccent.color)
                    .frame(width: 28, height: 28).background(Circle().fill(theme.accent.color.opacity(empty ? 0.4 : 1)))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .help("Send (↩)")
            .accessibilityLabel("Send")
            .testAnchor("agentpane.send")
        }
    }
}

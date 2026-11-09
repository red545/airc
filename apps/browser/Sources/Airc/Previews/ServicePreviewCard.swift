// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// What a service card shows (S04), kept current while it's up.
final class ServicePreviewModel: ObservableObject {
    @Published var account: PreviewAccount?
    @Published var state: PreviewState = .loading
    @Published var now = Date()
    /// The service's own icon (the row's favicon), for recent pages.
    @Published var icon: NSImage?
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    /// A new card each time it's shown (its list starts at the top).
    @Published var showID = 0
    var onMail: (PreviewMail) -> Void = { _ in }
    var onPage: (PreviewPage) -> Void = { _ in }
    var onEvent: (CalendarEvent) -> Void = { _ in }
    var onJoin: (CalendarEvent) -> Void = { _ in }
    var onAction: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onRemove: () -> Void = {}
    var onSettings: () -> Void = {}
}

/// The card beside a pinned tab or Favorite of a service (TabPreview.swift shows it in place of the page-picture card):
/// Arc's previews, measured from arc.net's integration recordings. Mail: the unread messages, newest first (the
/// sender, the subject, two lines of the text, its age) and "+" for a new message. A calendar: the day from the
/// current hour (an hour grid, the meetings as blocks side by side where they overlap, a line at now, a big Join for a
/// meeting moments away), the gear and "+" for a new event; dark, as Arc's was. Notion, Confluence, Figma and Linear:
/// the pages visited there, newest first, and "+" for a new one. The list scrolls inside the card.
final class ServicePreviewCardView: NSView {
    static let width: CGFloat = 240
    static let height: CGFloat = 268
    static let margin: CGFloat = 24

    let model = ServicePreviewModel()
    var onHover: ((Bool) -> Void)?
    private let host: AircFirstClickHostingView<ServiceCardContent>

    override init(frame: NSRect) {
        host = AircFirstClickHostingView(rootView: ServiceCardContent(model: model))
        super.init(frame: frame)
        wantsLayer = true
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var frameSize: NSSize { NSSize(width: width + 2 * margin, height: height + 2 * margin) }

    /// The card inside the view (the rest is room for the shadow).
    var cardRect: NSRect { NSRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, cardRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    #if AIRC_TESTING
    var hostingView: NSView { host }
    #endif
}

// MARK: - Content

private struct ServiceCardContent: View {
    @ObservedObject var model: ServicePreviewModel

    private var service: PreviewService? { model.account?.service }
    private var isCalendar: Bool { service?.family == .calendar }
    /// Arc's calendar card is dark whatever the window's theme.
    private var theme: ResolvedTheme { isCalendar ? DesignTheme.default.resolved(systemIsDark: true) : model.theme }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.popover, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if showsActions { actions.padding(10) }
        }
        .id(model.showID)
        .frame(width: ServicePreviewCardView.width, height: ServicePreviewCardView.height)
        .background(shape.fill(isCalendar ? Color(white: 0.17) : theme.surface.color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .clipShape(shape)
        .aircShadow(.popover)
        .padding(ServicePreviewCardView.margin)
        .testAnchorRoot()
        .aircTheme(theme)
        .environment(\.colorScheme, theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(service?.header ?? "").aircFont(AircFont.caption.weight(.medium)).foregroundStyle(theme.surfaceTextTertiary.color)
            Spacer(minLength: 0)
            if case .failed(let stale?) = model.state, !stale.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(theme.surfaceTextTertiary.color)
                    .help("Airc is having trouble getting new data, but will try again soon.")
            }
        }
        .padding(.horizontal, 12).frame(height: 26)
    }

    /// "+" (and a calendar's gear) float at the bottom right, over the list, as in Arc.
    private var showsActions: Bool {
        switch model.state {
        case .ready: true
        case .failed(let stale): stale != nil
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: loading
        case .signedOut: signedOut
        case .expired: expired
        case .ready(let c): list(c)
        case .failed(let stale):
            if let stale { list(stale) } else { failed }
        }
    }

    // MARK: States

    private var loading: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(theme.surfaceTextTertiary.color.opacity(0.18)).frame(width: 120 - CGFloat(i) * 14, height: 9)
                    RoundedRectangle(cornerRadius: 3).fill(theme.surfaceTextTertiary.color.opacity(0.12)).frame(width: 190, height: 8)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
        .accessibilityLabel("Loading")
        .testAnchor("svc.loading")
    }

    /// Arc's signed-out card: its sentence, centred, over a full-width button.
    private var signedOut: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text(service?.signInText ?? "").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(service?.signInButton ?? "Sign In") { model.onSignIn() }
                .buttonStyle(.airc(.secondary, size: .regular, fullWidth: true))
            .testAnchor("svc.signIn")
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
    }

    /// Arc: "You were signed out of …", Sign In or Remove.
    private var expired: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("You were signed out of \(service?.name ?? "this account").").aircFont(AircFont.body)
                .foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Remove") { model.onRemove() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("svc.remove")
                Button("Sign In") { model.onSignIn() }.buttonStyle(.airc(.primary, size: .small)).testAnchor("svc.signIn")
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 16)
    }

    private var failed: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(theme.surfaceTextTertiary.color)
            Text("Airc is having trouble getting new data, but will try again soon.").aircFont(AircFont.callout)
                .foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .testAnchor("svc.failed")
    }

    @ViewBuilder private func list(_ c: PreviewContent) -> some View {
        switch c {
        case .mail(let m): mailList(m)
        case .recents(let p): pageList(p)
        case .calendar(let e): PreviewTimelineView(events: e, now: model.now, theme: theme, onEvent: model.onEvent, onJoin: model.onJoin)
        }
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(text).aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 30)
        }
        .padding(.horizontal, 16)
        .testAnchor("svc.empty")
    }

    // MARK: Mail

    @ViewBuilder private func mailList(_ mail: [PreviewMail]) -> some View {
        if mail.isEmpty {
            empty(service?.emptyText ?? "")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(mail) { m in
                        MailRow(mail: m, now: model.now, theme: theme) { model.onMail(m) }
                        Divider().opacity(0.6).padding(.leading, 12)
                    }
                }
                .padding(.bottom, 44)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Recent pages

    @ViewBuilder private func pageList(_ pages: [PreviewPage]) -> some View {
        if pages.isEmpty {
            empty(service?.emptyText ?? "")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pages) { p in
                        PageRow(page: p, icon: model.icon, now: model.now, theme: theme) { model.onPage(p) }
                        Divider().opacity(0.6).padding(.leading, 40)
                    }
                }
                .padding(.bottom, 44)
            }
        }
    }

    // MARK: "+" and the gear

    private var actions: some View {
        HStack(spacing: 8) {
            if isCalendar {
                Button(action: model.onSettings) {
                    Image(systemName: "gearshape.fill").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(RoundButtonStyle(fill: Color(white: 0.27), ink: .white.opacity(0.85)))
                .help("Calendar Preview Settings")
                .testAnchor("svc.settings")
            }
            Button(action: model.onAction) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
            }
            .buttonStyle(RoundButtonStyle(fill: isCalendar ? Color(white: 0.35) : theme.surface.color,
                                          ink: isCalendar ? .white : theme.surfaceText.color, border: theme.surfaceBorder.color))
            .help(service?.actionTitle ?? "")
            .accessibilityLabel(service?.actionTitle ?? "")
            .testAnchor("svc.action")
        }
    }
}

/// Arc's round "+" and gear: a filled circle with a soft shadow, darker while pressed.
private struct RoundButtonStyle: ButtonStyle {
    var fill: Color
    var ink: Color
    var border: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .background(Circle().fill(fill).brightness(configuration.isPressed ? -0.08 : 0))
            .overlay(Circle().inset(by: 0.25).stroke(border, lineWidth: 0.5))
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .contentShape(Circle())
    }
}

private struct MailRow: View {
    let mail: PreviewMail
    let now: Date
    let theme: ResolvedTheme
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mail.sender).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(PreviewTime.mailAge(mail.date, now: now)).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                }
                Text(mail.subject).aircFont(AircFont.callout).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                Text(mail.snippet).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? theme.surfaceHover.color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .testAnchor("svc.mail.\(mail.id)")
    }
}

private struct PageRow: View {
    let page: PreviewPage
    let icon: NSImage?
    let now: Date
    let theme: ResolvedTheme
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else {
                        Image(systemName: "doc.text").resizable().scaledToFit().foregroundStyle(theme.surfaceTextSecondary.color)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                    Text(PreviewTime.pageAge(page.date, now: now)).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? theme.surfaceHover.color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(page.url)
        .testAnchor("svc.page.\(page.url)")
    }
}

// MARK: - The calendar's day

/// Arc's calendar preview: from the current hour, 40 pt an hour, labels in the Mac's time zone; meetings as blocks
/// (side by side where they overlap, PreviewTimeline.layout); a line at now; all-day events above; a big Join for a
/// meeting moments away (ten minutes, MeetingSchedule.soonJoin) or on now that has a call.
struct PreviewTimelineView: View {
    static let hourHeight: CGFloat = 40
    static let gutter: CGFloat = 46
    let events: [CalendarEvent]
    let now: Date
    let theme: ResolvedTheme
    let onEvent: (CalendarEvent) -> Void
    let onJoin: (CalendarEvent) -> Void

    private static let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    private var window: DateInterval { PreviewTimeline.window(now: now) }

    private var soon: [CalendarEvent] {
        events.filter { $0.link != nil && !$0.isAllDay && $0.start.timeIntervalSince(now) <= MeetingSchedule.soonJoin && now < $0.end }
            .sorted { $0.start < $1.start }
    }

    private func y(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(window.start) / 3600) * Self.hourHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(soon.prefix(2), id: \.id) { e in
                Button { onJoin(e) } label: {
                    Label(e.title.isEmpty ? "Join Event" : "Join \(e.title)", systemImage: "video.fill").lineLimit(1)
                }
                .buttonStyle(.airc(.primary, size: .regular, fullWidth: true))
                .padding(.horizontal, 10)
                .testAnchor("svc.join.\(e.id)")
            }
            let allDay = events.filter { $0.isAllDay && $0.end > now && $0.start <= window.end }
            if !allDay.isEmpty {
                Text("All day: " + allDay.map(\.title).joined(separator: ", ")).aircFont(AircFont.caption)
                    .foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1).padding(.horizontal, 12)
            }
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(PreviewTimeline.hours(in: window), id: \.self) { h in
                            HStack(alignment: .top, spacing: 4) {
                                Text(Self.hourFormat.string(from: h)).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                                    .frame(width: Self.gutter - 6, alignment: .leading).offset(y: -6)
                                Rectangle().fill(theme.surfaceBorder.color).frame(height: 0.5)
                            }
                            .frame(height: Self.hourHeight, alignment: .top)
                        }
                    }
                    .padding(.top, 8)
                    GeometryReader { geo in
                        let width = geo.size.width - Self.gutter - 8
                        ForEach(PreviewTimeline.layout(events, in: window), id: \.event.id) { b in
                            let colW = width / CGFloat(b.columns)
                            let top = max(0, y(b.event.start))
                            let h = max(18, y(b.event.end) - top - 2)
                            Button { onEvent(b.event) } label: {
                                Text(b.event.title).aircFont(AircFont.caption.weight(.medium)).foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(h > 30 ? 2 : 1).padding(.horizontal, 5).padding(.vertical, 3)
                                    .frame(width: colW - 2, height: h, alignment: .topLeading)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.accent.color.opacity(0.42)))
                                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .testAnchor("svc.event.\(b.event.id)")
                            .offset(x: Self.gutter + CGFloat(b.column) * colW, y: top + 8)
                        }
                        // Now.
                        let ny = y(now) + 8
                        HStack(spacing: 0) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                            Rectangle().fill(.white.opacity(0.9)).frame(height: 1.5)
                        }
                        .frame(width: geo.size.width - Self.gutter + 3)
                        .offset(x: Self.gutter - 3, y: ny - 3)
                    }
                    .frame(height: CGFloat(PreviewTimeline.hours(in: window).count) * Self.hourHeight + 8)
                }
                .padding(.leading, 10).padding(.trailing, 6).padding(.bottom, 48)
            }
        }
        .testAnchor("svc.timeline")
    }
}

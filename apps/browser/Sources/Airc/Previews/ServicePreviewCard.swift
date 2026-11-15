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
    /// calprev: the item's last page picture, shown dimmed behind "Open …" while no page of the account is loaded.
    @Published var snapshot: NSImage?
    /// The content is read from the account's own page (S04, calprev): Sign In and Open load that page; no gear.
    @Published var pageRead = false
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    /// A new card each time it's shown (its list starts at the top).
    @Published var showID = 0
    /// calcard: the card's height (ServicePreviewCardView.height(for:fitting:)): a calendar's is taller.
    @Published var cardHeight = ServicePreviewCardView.height
    var onMail: (PreviewMail) -> Void = { _ in }
    var onPage: (PreviewPage) -> Void = { _ in }
    var onEvent: (CalendarEvent) -> Void = { _ in }
    var onJoin: (CalendarEvent) -> Void = { _ in }
    var onAction: () -> Void = {}
    var onSignIn: () -> Void = {}
    /// S04: "Open Gmail" on a card waiting for the account's page (PreviewState.needsPage).
    var onOpenPage: () -> Void = {}
    var onRemove: () -> Void = {}
    var onSettings: () -> Void = {}
}

/// The card beside a pinned tab or Favorite of a service (TabPreview.swift shows it in place of the page-picture card):
/// Arc's previews, measured from arc.net's integration recordings. Mail: the unread messages, newest first (the
/// sender, the subject, two lines of the text, its age) and "+" for a new message. A calendar (calgrid): Arc's hour
/// grid, opened 15 minutes before now, the meetings as blocks side by side where they overlap, a line at now, today's
/// all-day events above, the big Join for one moments away, and tomorrow's later events in a short list under it; "+"
/// for a new event. Notion, Confluence, Figma and Linear:
/// the pages visited there, newest first, and "+" for a new one. The list scrolls inside the card.
final class ServicePreviewCardView: NSView {
    static let width: CGFloat = 240
    /// Mail and pages. A calendar's card is taller (calcard): see `height(for:fitting:)`.
    static let height: CGFloat = 268
    static let margin: CGFloat = 24

    /// The card's height for `service` in a window `available` points tall: a calendar's card is
    /// PreviewTimeline.CardLayout.calendarCardHeight, so Arc's six hours fit beside the Join, the all-day strip and
    /// Tomorrow; in a short window it's smaller (16 pt from the window's edges), and the hours shrink with it.
    static func height(for service: PreviewService?, fitting available: CGFloat) -> CGFloat {
        let want = service?.family == .calendar ? CGFloat(PreviewTimeline.CardLayout.calendarCardHeight) : height
        return max(height, min(want, available - 16)).rounded()
    }

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
    var cardRect: NSRect { NSRect(x: Self.margin, y: Self.margin, width: Self.width, height: model.cardHeight) }

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
    /// The window's theme, as Live Calendar's card (M08).
    private var theme: ResolvedTheme { model.theme }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.popover, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if showsActions { actions.padding(10).padding(.bottom, actionsLift) }
        }
        .id(model.showID)
        .frame(width: ServicePreviewCardView.width, height: model.cardHeight)
        .background(shape.fill(theme.surface.color))
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
        case .needsPage: needsPage
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

    /// Arc's signed-out card: its sentence, centred, over a full-width button. A calendar read from its page signs in
    /// there (calprev).
    private var signedOut: some View {
        let page = model.pageRead && isCalendar
        return VStack(spacing: 16) {
            Spacer(minLength: 0)
            Text(page ? "Sign in to \(service?.name ?? "your calendar") in this profile to see your events here." : service?.signInText ?? "")
                .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(page ? "Open \(service?.name ?? "Calendar")" : service?.signInButton ?? "Sign In") { model.onSignIn() }
                .buttonStyle(.airc(.secondary, size: .regular, fullWidth: true))
            .testAnchor("svc.signIn")
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
    }

    /// S04: mail is read from the account's own page, and none is loaded yet in this profile. calprev: the same for a
    /// calendar, over the item's last page picture when there is one.
    private var needsPage: some View {
        VStack(spacing: 16) {
            if isCalendar, let shot = model.snapshot {
                Image(nsImage: shot).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().opacity(0.55)
                    .overlay(LinearGradient(colors: [.clear, theme.surface.color], startPoint: .center, endPoint: .bottom))
                    .testAnchor("svc.snapshot")
            } else {
                Spacer(minLength: 0)
            }
            Text(isCalendar ? "Open \(service?.name ?? "your calendar") to see your events here."
                 : "Open \(service?.name ?? "your email") to see your unread messages here.").aircFont(AircFont.body)
                .foregroundStyle(theme.surfaceTextSecondary.color).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            Button("Open \(service?.name ?? (isCalendar ? "Calendar" : "Email"))") { model.onOpenPage() }
                .buttonStyle(.airc(.secondary, size: .regular, fullWidth: true))
                .padding(.horizontal, 14)
                .testAnchor("svc.openPage")
        }
        .padding(.bottom, 14)
        .testAnchor("svc.needsPage")
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
        case .calendar(let e):
            CalendarHourGrid(events: e, now: model.now, theme: theme, cardHeight: model.cardHeight, onEvent: model.onEvent, onJoin: model.onJoin)
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

    /// calcard: on a calendar with a Tomorrow line, "+" and the gear float over the hours' corner just above it, so the
    /// line keeps the card's whole width.
    private var actionsLift: CGFloat {
        guard case .calendar(let e)? = model.state.content, !PreviewTimeline.tomorrow(e, now: model.now).isEmpty else { return 0 }
        typealias L = PreviewTimeline.CardLayout
        return CGFloat(L.spacing + L.tomorrow + L.bottom) - 6
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if isCalendar, !model.pageRead {
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
            .buttonStyle(RoundButtonStyle(fill: theme.surface.color, ink: theme.surfaceText.color, border: theme.surfaceBorder.color))
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

/// calgrid: a calendar card's day as Arc 1.171's calendar preview laid it out (CalendarPreviewCalendarView,
/// CalendarLayout): hour lines labelled in a 45 pt gutter, each meeting a block at its time, overlapping ones side by
/// side (PreviewTimeline.layout), a line at now. Arc's card showed six hours from 15 minutes before now, spread over its
/// whole grid; this one does too (calcard: PreviewTimeline.CardLayout picks the hour height that fits them in the room
/// left), opens there and scrolls over the rest of today (and on past midnight while those six hours reach it). Above
/// the hours: Arc's big Join for a meeting with a call moments away (QuickJoinButton) and today's all-day events in one
/// line. Under them, tomorrow's later events in one line, which Arc didn't have. A click on a block or a chip opens the
/// event in the calendar's own pinned tab or Favorite.
struct CalendarHourGrid: View {
    /// Arc: the events' rect starts 45 pt in; the hour labels sit in that gutter.
    static let gutter: CGFloat = 45
    static let width: CGFloat = ServicePreviewCardView.width - 8
    static let topInset = CGFloat(PreviewTimeline.CardLayout.topInset)
    let events: [CalendarEvent]
    let now: Date
    let theme: ResolvedTheme
    /// The whole card's height, header included (ServicePreviewCardView.height(for:fitting:)).
    let cardHeight: CGFloat
    let onEvent: (CalendarEvent) -> Void
    let onJoin: (CalendarEvent) -> Void
    @State private var hovered: String?

    private static let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private func service(_ e: CalendarEvent) -> String? { e.link.map { CalendarCard.serviceName($0.service) } }

    /// What VoiceOver reads for an event: its title, its time, its call.
    private func spoken(_ e: CalendarEvent, day: String? = nil) -> String {
        let time = e.isAllDay ? "all day" : CalendarCard.timeRange(e, now: now)
        return [e.title.isEmpty ? "Event" : e.title, day, time, service(e)].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        typealias L = PreviewTimeline.CardLayout
        let window = PreviewTimeline.window(now: now)
        let allDay = PreviewTimeline.allDay(events, now: now)
        let soon = PreviewTimeline.soon(events, now: now).first
        let later = PreviewTimeline.tomorrow(events, now: now)
        let layout = L(events, now: now, cardHeight: Double(cardHeight))
        return VStack(alignment: .leading, spacing: 0) {
            if let soon {
                Button { onJoin(soon) } label: {
                    Label(soon.title.isEmpty ? "Join Event" : "Join \(soon.title)", systemImage: "video.fill").lineLimit(1)
                }
                .buttonStyle(.airc(.primary, size: .regular, fullWidth: true))
                .frame(height: L.join)
                .padding(.horizontal, 10)
                .padding(.bottom, L.spacing)
                .accessibilityHint("Opens the call")
                .testAnchor("svc.join.\(soon.id)")
            }
            if !allDay.isEmpty { allDayStrip(allDay).frame(height: L.allDay).padding(.bottom, L.spacing) }
            grid(window, hourHeight: CGFloat(layout.hourHeight)).frame(height: CGFloat(layout.gridHeight))
            if !later.isEmpty {
                tomorrowLine(later).frame(height: L.tomorrow).padding(.top, L.spacing).padding(.bottom, L.bottom)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .testAnchor("svc.calendar")
    }

    // MARK: Chips (all day, tomorrow)

    private func chip(_ e: CalendarEvent, text: Text, anchor: String, day: String? = nil) -> some View {
        Button { onEvent(e) } label: {
            text.aircFont(AircFont.caption.weight(.semibold)).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(blockFill(hovered: hovered == e.id)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .help(e.title)
        .accessibilityLabel(spoken(e, day: day))
        .accessibilityHint("Opens the event")
        .testAnchor("svc.event.\(e.id)")
        .testAnchor(anchor)
    }

    private func more(_ n: Int, spoken: String) -> some View {
        Text("+\(n)").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize()
            .accessibilityLabel(spoken)
    }

    /// Today's all-day events in one line: two chips, then "+N".
    private func allDayStrip(_ all: [CalendarEvent]) -> some View {
        let shown = all.prefix(2)
        return HStack(spacing: 4) {
            Text("all-day").aircFont(AircFont.micro).foregroundStyle(theme.surfaceTextTertiary.color)
                .frame(width: Self.gutter - 6, alignment: .leading)
                .accessibilityHidden(true)
            ForEach(Array(shown), id: \.id) { e in
                chip(e, text: Text(e.title), anchor: "svc.allDay.\(e.id)")
            }
            if all.count > shown.count { more(all.count - shown.count, spoken: "\(all.count - shown.count) more all-day events") }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .testAnchor("svc.allDay")
    }

    // MARK: The hours

    private func blockFill(hovered: Bool) -> Color {
        theme.accent.color.opacity(theme.isDark ? (hovered ? 0.42 : 0.32) : (hovered ? 0.26 : 0.17))
    }

    private func grid(_ w: DateInterval, hourHeight: CGFloat) -> some View {
        let hours = PreviewTimeline.hours(in: w)
        let blocks = PreviewTimeline.layout(events, in: w)
        func y(_ d: Date) -> CGFloat { CGFloat(PreviewTimeline.offset(of: d, in: w, hourHeight: Double(hourHeight))) + Self.topInset }
        let height = CGFloat(w.duration / 3600) * hourHeight + Self.topInset * 2
        let area = Self.width - Self.gutter - 6
        let top = max(0, y(PreviewTimeline.visible(now: now).start) - Self.topInset)
        let calendar = Calendar.current
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    // Where the card opens: 15 minutes before now at the top (Arc's window).
                    VStack(spacing: 0) {
                        Color.clear.frame(width: 1, height: top)
                        Color.clear.frame(width: 1, height: 1).id("svc.grid.open")
                    }
                    .accessibilityHidden(true)
                    ForEach(hours, id: \.self) { h in
                        let midnight = calendar.component(.hour, from: h) == 0 && h > w.start
                        HStack(alignment: .center, spacing: 4) {
                            Text(midnight ? Self.dayFormat.string(from: h) : Self.hourFormat.string(from: h))
                                .aircFont(midnight ? AircFont.caption.weight(.semibold) : AircFont.caption)
                                .foregroundStyle(midnight ? theme.surfaceTextSecondary.color : theme.surfaceTextTertiary.color)
                                .frame(width: Self.gutter - 8, alignment: .trailing)
                            Rectangle().fill(midnight ? theme.surfaceTextTertiary.color.opacity(0.6) : theme.surfaceBorder.color).frame(height: midnight ? 1 : 0.5)
                        }
                        .frame(width: Self.width - 4, height: 14)
                        .offset(y: y(h) - 7)
                        .accessibilityHidden(true)
                    }
                    ForEach(blocks, id: \.event.id) { b in
                        block(b, area: area, top: y(b.start), height: max(18, y(b.end) - y(b.start) - 2))
                    }
                    // Now (Arc's NowLine): a dot on the gutter's edge and a line over the events.
                    HStack(spacing: 0) {
                        Circle().fill(theme.accent.color).frame(width: 7, height: 7)
                        Rectangle().fill(theme.accent.color).frame(height: 1.5)
                    }
                    .frame(width: area + 7)
                    .testAnchor("svc.nowLine")
                    .offset(x: Self.gutter - 3.5, y: y(now) - 3.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .frame(width: Self.width, height: height, alignment: .topLeading)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.automatic)
            // Instant, so there's no motion to reduce: the card opens already scrolled.
            .onAppear { proxy.scrollTo("svc.grid.open", anchor: .top) }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today")
        .testAnchor("svc.grid")
    }

    private func block(_ b: PreviewTimeline.Block, area: CGFloat, top: CGFloat, height h: CGFloat) -> some View {
        let e = b.event
        let colW = area / CGFloat(b.columns)
        let over = e.end <= now
        let detail = [CalendarCard.timeRange(e, now: now), service(e)].compactMap { $0 }.joined(separator: " · ")
        let isHovered = hovered == e.id
        return Button { onEvent(e) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(e.title.isEmpty ? "Event" : e.title).aircFont(AircFont.caption.weight(.semibold))
                    .foregroundStyle(theme.surfaceText.color).lineLimit(h >= 44 ? 2 : 1)
                if h >= 30 {
                    Text(detail).aircFont(AircFont.micro.weight(.regular)).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                }
            }
            .padding(.leading, 7).padding(.trailing, 3).padding(.vertical, h >= 24 ? 3 : 1)
            .frame(width: max(8, colW - 2), height: h, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(blockFill(hovered: isHovered)))
            .overlay(alignment: .leading) { Rectangle().fill(theme.accent.color).frame(width: 2.5) }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(over ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .help(e.title)
        .accessibilityLabel(spoken(e))
        .accessibilityHint("Opens the event")
        .testAnchor("svc.event.\(e.id)")
        .offset(x: Self.gutter + CGFloat(b.column) * colW, y: top)
    }

    // MARK: Tomorrow

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// calcard: tomorrow in one line, so the six hours keep their room: "Tomorrow", the first event (all-day ones come
    /// first) as a chip with its time, then "+N". Arc had no Tomorrow at all.
    private func tomorrowLine(_ later: [CalendarEvent]) -> some View {
        let first = later[0]
        let text = first.isAllDay ? Text(first.title.isEmpty ? "Event" : first.title)
            : Text(Self.timeFormat.string(from: first.start) + " ").foregroundStyle(theme.surfaceTextSecondary.color)
                + Text(first.title.isEmpty ? "Event" : first.title)
        return HStack(spacing: 4) {
            Text("Tomorrow").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize()
                .accessibilityAddTraits(.isHeader)
                .testAnchor("svc.day.Tomorrow")
            chip(first, text: text, anchor: "svc.tomorrow.\(first.id)", day: "tomorrow")
            if later.count > 1 { more(later.count - 1, spoken: "\(later.count - 1) more tomorrow") }
            Spacer(minLength: 0)
        }
        .testAnchor("svc.tomorrow")
        .padding(.leading, 12).padding(.trailing, 8)
    }
}

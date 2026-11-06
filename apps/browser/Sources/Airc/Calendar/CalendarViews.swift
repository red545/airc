// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

// MARK: - The Calendar Favorite's countdown

/// On a Calendar Favorite tile (CalendarSites): the countdown to the next meeting ("in 5m") beside the date icon, or
/// under it on a narrow tile. Owned by the tile; follows CalendarCenter on its own, without a page reload.
final class CalendarTileFace {
    private weak var tile: FavoriteTileView?
    let label = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    private var palette: Palette?
    private var promptCheckQueued = false
    /// What the tile shows now (nil: no countdown).
    var text: String? { label.isHidden ? nil : label.stringValue }

    static func isCalendar(_ item: Item) -> Bool { item.kind != .split && CalendarSites.isCalendarFavorite(item.savedURL ?? "") }

    init(tile: FavoriteTileView) {
        self.tile = tile
        label.font = AircFont.caption.weight(.semibold).appFont
        label.lineBreakMode = .byClipping
        label.isHidden = true
        tile.addSubview(label)
        observer = NotificationCenter.default.addObserver(forName: CalendarCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
            self?.queuePromptCheck()
        }
        CalendarCenter.shared.faceAppeared()
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        label.removeFromSuperview()
        CalendarCenter.shared.faceGone()
    }

    func configure(palette: Palette) {
        self.palette = palette
        refresh()
    }

    func refresh() {
        let center = CalendarCenter.shared
        let text = center.tileLabel
        if label.isHidden != (text == nil) || label.stringValue != (text ?? "") {
            label.stringValue = text ?? ""
            label.isHidden = text == nil
            tile?.needsLayout = true
        }
        if let palette { label.textColor = text == "now" ? palette.textPrimary : palette.textSecondary }
    }

    /// The Join prompt under the grid comes and goes with a page reload (SpacePageView.render places it). Checked after
    /// the change has gone round, never from inside a render.
    private func queuePromptCheck() {
        guard !promptCheckQueued else { return }
        promptCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.promptCheckQueued = false
            guard let tile = self.tile, let grid = tile.superview else { return }
            let shown = grid.subviews.contains { $0 is CalendarPromptView }
            if (CalendarCenter.shared.promptEvent != nil) != shown { tile.page?.reload(animated: true) }
        }
    }

    /// After the tile centred its icon: the icon and the countdown side by side, or stacked when the tile is narrow.
    func layout(in b: NSRect, favicon: NSView) {
        guard !label.isHidden else { return }
        let s = favicon.frame.width, gap: CGFloat = 5
        let size = label.intrinsicContentSize
        let w = ceil(size.width), h = ceil(size.height)
        if b.width >= s + gap + w + 16 {
            let x = floor((b.width - s - gap - w) / 2)
            favicon.frame.origin.x = x
            label.frame = NSRect(x: x + s + gap, y: floor((b.height - h) / 2), width: w, height: h)
        } else {
            let top = floor((b.height - s - h) / 2) + 1
            favicon.frame.origin.y = top
            label.frame = NSRect(x: floor((b.width - w) / 2), y: top + s, width: w, height: h)
        }
    }

    func hover(_ inside: Bool) {
        guard let tile else { return }
        if inside { CalendarCard.shared.hoverBegan(tile: tile) } else { CalendarCard.shared.hoverEnded() }
    }
}

// MARK: - The hover card

/// What the card lists, kept current while it's up.
final class CalendarCardModel: ObservableObject {
    @Published var state: CalendarCenter.CardState = .events
    @Published var events: [CalendarEvent] = []
    @Published var labels: [String: String] = [:]
    var theme = DesignTheme.default.resolved(systemIsDark: false)
    var onJoin: (CalendarEvent) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    func update() {
        let c = CalendarCenter.shared
        if let s = c.cardState, s != state { state = s }
        let e = c.upcoming
        if e != events { events = e }
        let l = Dictionary(uniqueKeysWithValues: e.compactMap { ev in c.label(for: ev).map { (ev.id, $0) } })
        if l != labels { labels = l }
    }
}

/// Hovering the Calendar Favorite for 0.45 s (like a folder's preview) shows the next meetings, each with Join when
/// it has a call link; before the feature is on, the one-time "Show your next meetings here?" instead. 4 pt right of
/// the sidebar, `popover` elevation, 90 ms in.
final class CalendarCard {
    static let shared = CalendarCard()
    static let width: CGFloat = 272
    static let shadowMargin: CGFloat = 20

    let model = CalendarCardModel()
    private(set) var panel: NSView?
    private weak var controller: WindowController?
    /// The Space whose Calendar Favorite opened the card: Join opens there.
    private(set) var spaceID: String?
    private weak var tile: NSView?
    private var pending: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var insidePanel = false
    private var observer: NSObjectProtocol?

    private init() {
        model.onJoin = { [weak self] e in
            guard let self, let c = self.controller else { return }
            CalendarCenter.shared.join(e, spaceID: self.spaceID, controller: c)
        }
        model.onHover = { [weak self] inside in
            self?.insidePanel = inside
            if inside { self?.hideWork?.cancel() } else { self?.scheduleHide() }
        }
        observer = NotificationCenter.default.addObserver(forName: CalendarCenter.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel != nil else { return }
            if CalendarCenter.shared.cardState == nil { return self.hide() }
            self.model.update()
            self.resize()
        }
    }

    func hoverBegan(tile: FavoriteTileView) {
        hideWork?.cancel()
        if panel != nil, self.tile === tile { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak tile] in
            guard let self, let tile, tile.window != nil else { return }
            self.show(beside: tile)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FolderPreviewController.delay, execute: work)
    }

    func hoverEnded() {
        pending?.cancel()
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.insidePanel else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func hide() {
        pending?.cancel()
        guard let p = panel else { return }
        panel = nil
        tile = nil
        insidePanel = false
        p.removeFromSuperview()
    }

    /// Shows the card beside `tile` now (scripted runs call this instead of hovering).
    func show(beside tile: FavoriteTileView) {
        guard let c = tile.controller, CalendarCenter.shared.cardState != nil else { return }
        hide()
        controller = c
        spaceID = tile.page?.spaceID
        self.tile = tile
        model.theme = c.currentPalette.resolved
        model.update()
        let host = AircFirstClickHostingView(rootView: CalendarCardView(model: model))
        host.safeAreaRegions = []
        host.wantsLayer = true
        c.root.addSubview(host)
        panel = host
        resize()
        host.layer?.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
        // Ask once more when the card opens: access may have changed in System Settings.
        CalendarCenter.shared.accessChanged()
    }

    /// Beside the sidebar, its top level with the tile's, kept inside the window.
    private func resize() {
        guard let host = panel, let c = controller, let tile else { return }
        let m = Self.shadowMargin
        let size = host.fittingSize
        let height = size.height - 2 * m
        let tileInRoot = tile.convert(tile.bounds, to: c.root)
        let onRight = c.sidebar.frame.minX > c.root.bounds.midX
        let x = onRight ? c.sidebar.frame.minX - 4 - Self.width - m : c.sidebar.frame.maxX + 4 - m
        let y = min(max(8, tileInRoot.minY), c.root.bounds.height - height - 8) - m
        host.frame = NSRect(x: x, y: y, width: Self.width + 2 * m, height: size.height)
    }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
    }

    static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "10:30 – 11:00", with "Tomorrow" for a meeting on the next day.
    static func timeRange(_ e: CalendarEvent, now: Date) -> String {
        let range = timeFormat.string(from: e.start) + " – " + timeFormat.string(from: e.end)
        return Calendar.current.isDate(e.start, inSameDayAs: now) || e.start < now ? range : "Tomorrow, " + range
    }

    static func serviceName(_ s: MeetingLink.Service) -> String {
        switch s {
        case .meet: "Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .webex: "Webex"
        case .web: "Video call"
        }
    }
}

private struct CalendarCardView: View {
    @ObservedObject var model: CalendarCardModel
    @State private var hovered: String?

    private var theme: ResolvedTheme { model.theme }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.popover, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .invitation: invitation
            case .denied: denied
            case .events: events
            }
        }
        .frame(width: CalendarCard.width, alignment: .leading)
        .background(shape.fill(theme.surface.color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .clipShape(shape)
        .aircShadow(.popover)
        .onHover(perform: model.onHover)
        .padding(CalendarCard.shadowMargin)
        .testAnchorRoot()
        .aircTheme(theme)
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent.color)
            Text("Show your next meetings here?").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Text("A countdown on this Favorite, your next meetings when you point at it, and Join for their calls. "
                 + "Airc reads the calendars on this Mac; nothing leaves it.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not Now") { CalendarCenter.shared.dismissInvitation() }
                    .buttonStyle(.airc(.secondary, size: .small)).testAnchor("calendar.notNow")
                Button("Turn On") { CalendarCenter.shared.setEnabled(true) }
                    .buttonStyle(.airc(.primary, size: .small)).testAnchor("calendar.turnOn")
            }
            .padding(.top, 4)
        }
        .padding(14)
    }

    private var denied: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access is off").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Text("Allow Airc in System Settings → Privacy & Security → Calendars to see your next meetings here.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Open System Settings") { CalendarCard.openPrivacySettings() }.buttonStyle(.airc(.secondary, size: .small))
            }
        }
        .padding(14)
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upcoming").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            if model.events.isEmpty {
                Text("No meetings in the next 24 hours").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(Array(model.events.enumerated()), id: \.element.id) { i, e in
                row(e, index: i)
            }
        }
        .padding(.bottom, 8)
    }

    private func row(_ e: CalendarEvent, index: Int) -> some View {
        let label = model.labels[e.id]
        let detail = [label, CalendarCard.timeRange(e, now: CalendarCenter.shared.now()),
                      e.link.map { CalendarCard.serviceName($0.service) }].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(label != nil ? theme.accent.color : theme.surfaceTextTertiary.color.opacity(0.5))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).aircFont(AircFont.body.weight(.medium)).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                Text(detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
            if e.link != nil {
                Button("Join") { model.onJoin(e) }
                    .buttonStyle(.airc(label != nil ? .primary : .secondary, size: .small))
                    .fixedSize()
                    .testAnchor("calendar.join.\(index)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
            .fill(hovered == e.id ? theme.surfaceHover.color : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
    }
}

// MARK: - The sidebar's "Meeting in 1 min · Join"

/// Under the Favorites grid of a Space with a Calendar Favorite, from a minute before a meeting with a call link to
/// five minutes after it starts: its title over "in 1 min" or "now", and Join. A click anywhere joins; ✕ closes it.
final class CalendarPromptView: NSView {
    static let height: CGFloat = 44
    static let gap: CGFloat = 6

    weak var controller: WindowController?
    var spaceID: String?
    private(set) var event: CalendarEvent?
    private let plate = CALayer()
    private let icon = CALayer()
    let title = NSTextField(labelWithString: "")
    /// "in 1 min" or "now", under the title.
    let when = NSTextField(labelWithString: "")
    private let pill = CALayer()
    private let pillLabel = NSTextField(labelWithString: "Join")
    let close = GlyphButton(symbol: "xmark", size: 9)
    private var palette: Palette?
    private var hovered = false { didSet { if hovered != oldValue { style(); needsLayout = true } } }
    private var observer: NSObjectProtocol?

    /// SpacePageView.render: adds, updates or removes the prompt below the grid; returns the height it adds.
    static func place(in grid: NSView, below gridHeight: CGFloat, width: CGFloat, favorites: [Item], spaceID: String,
                      palette: Palette, controller: WindowController) -> CGFloat {
        let existing = grid.subviews.first { $0 is CalendarPromptView } as? CalendarPromptView
        guard favorites.contains(where: CalendarTileFace.isCalendar), let e = CalendarCenter.shared.promptEvent else {
            existing?.removeFromSuperview()
            return 0
        }
        let v = existing ?? {
            let v = CalendarPromptView()
            grid.addSubview(v)
            v.layer?.fade(from: 0, to: 1, duration: 0.15)
            return v
        }()
        v.controller = controller
        v.spaceID = spaceID
        v.configure(e, palette: palette)
        v.frame = NSRect(x: 0, y: gridHeight + gap, width: width, height: height)
        return gap + height
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [plate, icon, pill] {
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        plate.cornerRadius = AircRadius.row
        plate.cornerCurve = .continuous
        pill.cornerRadius = 11
        pill.cornerCurve = .continuous
        icon.contentsGravity = .center
        title.font = AircFont.body.weight(.medium).appFont
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        pillLabel.font = AircFont.callout.weight(.semibold).appFont
        pillLabel.alignment = .center
        when.font = AircFont.callout.appFont
        when.lineBreakMode = .byClipping
        addSubview(title)
        addSubview(when)
        addSubview(pillLabel)
        addSubview(close)
        close.toolTip = "Dismiss"
        close.action = { [weak self] in
            guard let id = self?.event?.id else { return }
            CalendarCenter.shared.dismissPrompt(id)
        }
        observer = NotificationCenter.default.addObserver(forName: CalendarCenter.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, let palette = self.palette, let e = CalendarCenter.shared.promptEvent, e.id == self.event?.id else { return }
            self.configure(e, palette: palette)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What it says: "Standup · in 1 min".
    var text: String { title.stringValue + " · " + when.stringValue }

    func configure(_ e: CalendarEvent, palette: Palette) {
        event = e
        self.palette = palette
        title.stringValue = e.title
        title.textColor = palette.textPrimary
        when.stringValue = CalendarCenter.shared.promptLabel(for: e)
        when.textColor = palette.textSecondary
        toolTip = e.title + " · " + CalendarCard.timeRange(e, now: CalendarCenter.shared.now())
        LayerImage.set(LayerImage.symbol("video.fill", size: 11, weight: .semibold, color: palette.resolved.accent.nsColor), on: icon, in: self)
        close.tint = palette.glyph
        close.hoverFill = palette.hover
        style()
        needsLayout = true
    }

    private func style() {
        guard let palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = (hovered ? palette.tileHover : palette.tileFill).cgColor
        pill.backgroundColor = palette.resolved.accent.nsColor.cgColor
        pillLabel.textColor = palette.resolved.onAccent.nsColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let pw = ceil(pillLabel.intrinsicContentSize.width) + 20
        pill.frame = NSRect(x: bounds.width - 8 - pw, y: (bounds.height - 22) / 2, width: pw, height: 22)
        CATransaction.commit()
        let ph = ceil(pillLabel.intrinsicContentSize.height)
        pillLabel.frame = NSRect(x: pill.frame.minX, y: pill.frame.midY - ph / 2, width: pw, height: ph)
        close.isHidden = !hovered
        close.frame = NSRect(x: pill.frame.minX - 4 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let end = hovered ? close.frame.minX - 4 : pill.frame.minX - 8
        // Two lines: the title (truncating), then "in 1 min".
        let th = ceil(title.intrinsicContentSize.height), wh = ceil(when.intrinsicContentSize.height)
        let top = floor((bounds.height - th - wh) / 2)
        title.frame = NSRect(x: 32, y: top, width: max(0, end - 32), height: th)
        when.frame = NSRect(x: 32, y: top + th, width: max(0, end - 32), height: wh)
    }

    /// Where Join is, in this view (scripted runs click it).
    var joinRect: NSRect { pill.frame }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard let e = self.event, let c = controller else { return }
        CalendarCenter.shared.join(e, spaceID: spaceID, controller: c)
    }
}

// MARK: - Settings → General → Calendar

struct CalendarSettingsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var center = CalendarCenter.shared

    var body: some View {
        SettingsSection(title: "Calendar",
                        help: "Works with a calendar Favorite (Google Calendar, Outlook, Proton or Fastmail) and the calendars on this Mac, "
                            + "set up in System Settings → Internet Accounts. Nothing leaves your Mac.") {
            AircToggleRow("Show upcoming meetings",
                          subtitle: "A countdown on the calendar Favorite, your next meetings when you point at it, and Join when one starts.",
                          isOn: Binding(get: { model.settings.values.calendar.enabled }, set: { center.setEnabled($0) }))
            if model.settings.values.calendar.enabled && center.access == .denied {
                SettingsRow(title: "Calendar access is off", subtitle: "Allow Airc in System Settings → Privacy & Security → Calendars.") {
                    Button("Open System Settings") { CalendarCard.openPrivacySettings() }.buttonStyle(.airc(.secondary))
                }
            }
        }
    }
}

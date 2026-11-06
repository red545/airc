// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

// MARK: - Library › Downloads (SB-62)

/// Running and past downloads, newest first by day, searchable by name or site. A row opens its file; on hover it has
/// pause / resume, cancel, retry and Show in Finder; its menu also copies the link and takes it off the list. A finished
/// file drags out.
struct LibraryDownloadsView: View {
    @ObservedObject var center: DownloadCenter
    @Binding var query: String
    let theme: ResolvedTheme
    let profileName: (String) -> String?

    struct Day: Identifiable {
        var id: String { title }
        var title: String
        var items: [DownloadCenter.Item]
    }

    private var days: [Day] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        var out: [Day] = []
        for i in center.items where q.isEmpty || CommandSearch.score(q, in: i.download.fileName) != nil
            || CommandSearch.score(q, in: URLRules.displayHost(i.download.url)) != nil {
            let when = i.download.startTime ?? Date()
            let title: String
            if cal.isDateInToday(when) { title = "Today" }
            else if cal.isDateInYesterday(when) { title = "Yesterday" }
            else { title = when.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if out.last?.title == title { out[out.count - 1].items.append(i) } else { out.append(Day(title: title, items: [i])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
                TextField("", text: $query, prompt: Text("Search downloads").foregroundStyle(theme.textTertiary.color))
                    .textFieldStyle(.plain).aircFont(AircFont.body).foregroundStyle(theme.text.color)
                    .testAnchor("library.downloads.search")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            let days = days
            if days.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 22, weight: .light)).foregroundStyle(theme.textTertiary.color)
                    Text(query.isEmpty ? "Files you download show up here." : "No downloads match.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days) { day in
                            Text(day.title).aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color)
                                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 4)
                            ForEach(day.items) { i in
                                LibraryDownloadRow(item: i, center: center, profileName: profileName(i.profileID))
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

private struct LibraryDownloadRow: View {
    let item: DownloadCenter.Item
    @ObservedObject var center: DownloadCenter
    let profileName: String?
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var d: EngineDownload { item.download }

    var body: some View {
        HStack(spacing: 10) {
            DownloadGlyph(download: d, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.fileName).aircFont(AircFont.row).foregroundStyle(theme.text.color.opacity(d.state == .cancelled ? 0.6 : 1))
                    .lineLimit(1).truncationMode(.middle)
                Text([DownloadCenter.status(item), profileName].compactMap { $0 }.joined(separator: " · "))
                    .aircFont(AircFont.caption)
                    .foregroundStyle((d.dangerous ? AircColor.downloadWarning : theme.textTertiary).color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if d.dangerous {
                Button("Keep…") { center.askAgain(item) }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("library.keep.\(d.id)")
                Button("Discard") { center.perform(.discard, item) }.buttonStyle(.airc(.primary, size: .small)).testAnchor("library.discard.\(d.id)")
            } else if hovered {
                actions
            } else if let end = d.endTime, d.state != .inProgress {
                Text(end.formatted(date: .omitted, time: .shortened)).aircFont(AircFont.mono).foregroundStyle(theme.textTertiary.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(hovered ? theme.hoverFill.color : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if d.state == .complete { center.open(item) } }
        .downloadDrag(item, center: center)
        .contextMenu { menu }
        .help(d.state == .complete ? "Open" : d.url)
        .testAnchor("library.download.\(d.id)")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 0) {
            switch d.state {
            case .inProgress:
                TrayButton(symbol: d.paused ? "play.fill" : "pause.fill", help: d.paused ? "Resume" : "Pause",
                           anchor: "library.pause.\(d.id)") { center.perform(d.paused ? .resume : .pause, item) }
                TrayButton(symbol: "xmark", help: "Cancel", anchor: "library.cancel.\(d.id)") { center.perform(.cancel, item) }
            case .interrupted, .cancelled:
                TrayButton(symbol: "arrow.clockwise", help: "Retry", anchor: "library.retry.\(d.id)") { center.perform(.retry, item) }
                TrayButton(symbol: "xmark", help: "Remove from List", anchor: "library.remove.\(d.id)") { center.perform(.remove, item) }
            case .complete:
                TrayButton(symbol: "magnifyingglass", help: "Show in Finder", anchor: "library.reveal.\(d.id)") { center.showInFinder(item) }
                TrayButton(symbol: "xmark", help: "Remove from List", anchor: "library.remove.\(d.id)") { center.perform(.remove, item) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if d.state == .complete {
            Button("Open") { center.open(item) }
            Button("Show in Finder") { center.showInFinder(item) }
        }
        if d.state == .inProgress, !d.dangerous {
            Button(d.paused ? "Resume" : "Pause") { center.perform(d.paused ? .resume : .pause, item) }
            Button(d.openWhenComplete ? "Don't Open When Done" : "Open When Done") { center.perform(.open, item) }
            Button("Cancel") { center.perform(.cancel, item) }
        }
        if d.state == .interrupted || d.state == .cancelled {
            Button("Retry") { center.perform(.retry, item) }
        }
        Divider()
        Button("Copy Download Link") { center.copyLink(item) }
        if d.state != .inProgress {
            Button("Remove from List") { center.perform(.remove, item) }
        }
    }
}

// MARK: - The risky-file and close questions

/// The cards over the sidebar's downloads: "may be harmful — Keep or Discard", and "downloads are still running" before
/// a close or quit. Arc's look (the page prompts' surface panel, PagePrompts.swift), hanging above the tray.
final class DownloadPrompts {
    private weak var controller: WindowController?
    private weak var library: MediaLibrary?
    private var bubble: DownloadBubbleView?
    private var closeAnswer: ((Bool) -> Void)?
    private var shownKey: String?
    private var resize: NSObjectProtocol?
    private var contentChange: AnyCancellable?

    init(controller: WindowController, library: MediaLibrary) {
        self.controller = controller
        self.library = library
        // The card stays above the tray as the window resizes.
        resize = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: controller.root,
                                                        queue: .main) { [weak self] _ in self?.layout() }
    }

    deinit { resize.map(NotificationCenter.default.removeObserver) }

    /// The card on screen now (the scripted checks click it).
    var view: DownloadBubbleView? { bubble }

    /// A risky download arrived or was answered.
    func refresh() {
        if closeAnswer != nil { return }
        let danger = library?.downloads?.dangerous
        if let danger {
            guard danger.id != shownKey else { return bubble?.model.update(danger) ?? () }
            show(.danger(danger))
            shownKey = danger.id
        } else if shownKey != nil {
            hide()
        }
    }

    /// Asks once; `answer(true)` closes anyway. A second ask while one is up answers the first "no".
    func askBeforeClosing(count: Int, _ answer: @escaping (Bool) -> Void) {
        closeAnswer?(false)
        closeAnswer = answer
        show(.close(count))
        shownKey = nil
    }

    private func show(_ kind: DownloadCardModel.Kind) {
        guard let c = controller else { return }
        hide(animated: false)
        let model = DownloadCardModel(kind: kind, theme: c.currentPalette.resolved)
        model.onAnswer = { [weak self] a in self?.answer(a) }
        let v = DownloadBubbleView(model: model)
        c.root.addSubview(v, positioned: .below, relativeTo: c.toast)
        bubble = v
        layout()
        v.present()
        // Keep… asks to confirm in longer words: the card grows (upward, from the tray) to fit.
        contentChange = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
    }

    private func answer(_ a: DownloadCardModel.Answer) {
        // This card goes first: answering can bring the next risky download's.
        shownKey = nil
        hide()
        switch a {
        case .keep: library?.downloads?.answerDanger(keep: true)
        case .discard: library?.downloads?.answerDanger(keep: false)
        case .later: library?.downloads?.dismissDanger()
        case .closeAnyway, .keepDownloading:
            let done = closeAnswer
            closeAnswer = nil
            done?(a == .closeAnyway)
        }
        refresh()
    }

    private func hide(animated: Bool = true) {
        guard let b = bubble else { return }
        bubble = nil
        guard animated, let layer = b.layer else { return b.removeFromSuperview() }
        layer.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { b.removeFromSuperview() }
    }

    /// Above whatever sits on top of the sidebar's footer (the tray, else the update pill), inset like its rows, so the
    /// card never covers the pill and both take clicks; with the sidebar hidden, at the page's bottom-left.
    func layout() {
        guard let c = controller, let b = bubble else { return }
        let size = b.fittingCardSize
        let tray = c.sidebar.tray, update = c.sidebar.update
        let anchor: NSRect
        if c.sidebarFraction >= 1, c.library == nil, tray.height > 0 || update.height > 0 {
            // The tray sits above the pill, so its top is the higher of the two. Both views' heights include their
            // 6 pt top inset: the card keeps the rows' 12 pt from the content under it, as above the tray.
            let top: NSView = tray.height > 0 ? tray : update
            anchor = c.root.convert(top.bounds, from: top)
        } else if c.sidebarFraction >= 1 {
            anchor = c.root.convert(c.sidebar.footer.bounds, from: c.sidebar.footer)
        } else {
            anchor = NSRect(x: c.card.frame.minX, y: c.card.frame.maxY - 10, width: 0, height: 0)
        }
        let x = min(max(8, anchor.minX + AircMetrics.Sidebar.inset), max(8, c.root.bounds.width - size.width - 8))
        b.place(at: NSPoint(x: x, y: max(8, anchor.minY - 6 - size.height)))
    }
}

final class DownloadCardModel: ObservableObject {
    enum Kind: Equatable {
        case danger(DownloadCenter.Item)
        case close(Int)
    }
    enum Answer { case keep, discard, later, closeAnyway, keepDownloading }

    @Published var kind: Kind
    /// Keep was pressed once: the card asks to confirm it.
    @Published var confirmingKeep = false
    let theme: ResolvedTheme
    var onAnswer: ((Answer) -> Void)?

    init(kind: Kind, theme: ResolvedTheme) {
        self.kind = kind
        self.theme = theme
    }

    func update(_ item: DownloadCenter.Item) {
        if case .danger = kind { kind = .danger(item) }
    }
}

struct DownloadCard: View {
    @ObservedObject var model: DownloadCardModel
    static let width: CGFloat = 300
    private var ui: ResolvedTheme { model.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.kind {
            case .danger(let i): danger(i)
            case .close(let n): closing(n)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .testAnchorRoot()
        .aircTheme(ui)
    }

    private func header(_ symbol: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                    .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func danger(_ i: DownloadCenter.Item) -> some View {
        let d = i.download
        let site = URLRules.displayHost(d.referrer ?? d.url)
        header("exclamationmark.triangle.fill", tint: AircColor.downloadWarning.color, title: "“\(d.fileName)” may be harmful",
               subtitle: [site.isEmpty ? nil : site, d.total.map(DownloadCenter.size)].compactMap { $0 }.joined(separator: " · "))
        Text(model.confirmingKeep ? "Keep it only if you trust where it came from. It can change files and settings on your Mac."
             : DownloadCenter.dangerText(d))
            .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        HStack(spacing: 8) {
            if model.confirmingKeep {
                Button("Cancel") { model.confirmingKeep = false }.buttonStyle(.airc(.secondary)).testAnchor("download.keepCancel")
                Spacer(minLength: 0)
                Button("Keep Anyway") { model.onAnswer?(.keep) }.buttonStyle(.airc(.destructive)).testAnchor("download.keepAnyway")
            } else {
                Button("Later") { model.onAnswer?(.later) }.buttonStyle(.airc(.plain)).testAnchor("download.later")
                Spacer(minLength: 0)
                if d.canKeep {
                    Button("Keep…") { model.confirmingKeep = true }.buttonStyle(.airc(.secondary)).testAnchor("download.keep")
                }
                Button("Discard") { model.onAnswer?(.discard) }.buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction)
                    .testAnchor("download.discard")
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func closing(_ n: Int) -> some View {
        header("arrow.down.circle.fill", tint: ui.accent.color,
               title: n == 1 ? "A download is still running" : "\(n) downloads are still running", subtitle: nil)
        Text(n == 1 ? "Closing now cancels it." : "Closing now cancels them.")
            .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
            .padding(.top, 10)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(n == 1 ? "Cancel Download" : "Cancel Downloads") { model.onAnswer?(.closeAnyway) }
                .buttonStyle(.airc(.secondary)).testAnchor("download.closeAnyway")
            Button("Keep Downloading") { model.onAnswer?(.keepDownloading) }
                .buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction).testAnchor("download.keepDownloading")
        }
        .padding(.top, 14)
        .onExitCommand { model.onAnswer?(.keepDownloading) }
    }
}

/// The card's view: the surface panel with the popover shadow (as PromptBubbleView), taking the first click.
final class DownloadBubbleView: NSView {
    let model: DownloadCardModel
    private let host: AircFirstClickHostingView<DownloadCard>

    init(model: DownloadCardModel) {
        self.model = model
        host = AircFirstClickHostingView(rootView: DownloadCard(model: model))
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
    var fittingCardSize: NSSize { host.fittingSize }

    func place(at origin: NSPoint) {
        let size = host.fittingSize
        frame = NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: size.height)
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

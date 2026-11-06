// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

/// SB-54: above the footer, the players of tabs playing in the background (any Space) and the downloads, as in Arc
/// (Arc ref §2.9): 40 pt rows, 6 pt apart, at most three players (more condense into the last row's menu, one on a
/// short window), at most two downloads (more condense into one summary row). It grows and shrinks on the row spring,
/// rising out of the footer; with nothing to show it takes no space.
final class SidebarTrayView: NSView {
    static let rowHeight: CGFloat = 40
    static let gap: CGFloat = 6
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 2

    /// The height the sidebar gives it now (animated).
    private(set) var height: CGFloat = 0
    let model = TrayModel()
    private var host: AircFirstClickHostingView<TrayContent>?
    private weak var controller: WindowController?
    private weak var library: MediaLibrary?
    private var target: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func connect(_ library: MediaLibrary, controller: WindowController) {
        self.library = library
        self.controller = controller
        model.library = library
        if host == nil {
            let h = AircFirstClickHostingView(rootView: TrayContent(model: model))
            h.safeAreaRegions = []
            addSubview(h)
            host = h
        }
        contentChanged()
    }

    func setTheme(_ theme: ResolvedTheme) {
        if model.theme != theme { model.theme = theme }
    }

    /// The players or downloads changed: the rows, and the height on the spring.
    func contentChanged() {
        guard let library else { return }
        let compact = (superview?.bounds.height ?? 900) < 620
        let plan = TrayPlan(players: library.media?.players ?? [], downloads: library.downloads?.sidebarItems ?? [],
                            maxPlayers: compact ? 1 : 3)
        if plan != model.plan { model.plan = plan }
        let h = plan.height
        guard h != target else { return }
        target = h
        guard let c = controller, window != nil, !isHiddenOrHasHiddenAncestor else { return setHeight(h) }
        let from = height
        c.animator.spring("tray", from: Double(from), to: Double(h), velocity: 0, spring: Spring(AircSpring.row), update: { [weak self] v in
            self?.setHeight(CGFloat(v))
        }, completion: { [weak self] in self?.setHeight(h) })
    }

    private func setHeight(_ h: CGFloat) {
        height = max(0, h)
        needsLayout = true
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
        library?.layoutPrompts()
        UpdateCenter.shared.confirm?.layoutInWindow()
    }

    override func layout() {
        super.layout()
        // The rows are laid out at their full height, bottom-aligned, and show as the tray opens over them.
        let full = max(target, bounds.height)
        host?.frame = NSRect(x: 0, y: bounds.height - full, width: bounds.width, height: full)
    }
}

/// What the tray shows, row by row (its height follows from it).
struct TrayPlan: Equatable {
    var players: [MediaCenter.Player] = []
    /// Players beyond the last row (they're in its menu).
    var morePlayers: [MediaCenter.Player] = []
    var downloads: [DownloadCenter.Item] = []
    /// Three or more downloads: one row for all of them.
    var summary: [DownloadCenter.Item] = []

    init() {}

    init(players all: [MediaCenter.Player], downloads d: [DownloadCenter.Item], maxPlayers: Int) {
        if all.count > maxPlayers {
            players = Array(all.prefix(maxPlayers))
            morePlayers = Array(all.dropFirst(maxPlayers))
        } else {
            players = all
        }
        if d.count > 2 { summary = d } else { downloads = d }
    }

    var rows: Int { players.count + downloads.count + (summary.isEmpty ? 0 : 1) }

    var height: CGFloat {
        let n = rows
        guard n > 0 else { return 0 }
        return SidebarTrayView.topInset + CGFloat(n) * SidebarTrayView.rowHeight + CGFloat(n - 1) * SidebarTrayView.gap
            + SidebarTrayView.bottomInset
    }
}

final class TrayModel: ObservableObject {
    @Published var plan = TrayPlan()
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    weak var library: MediaLibrary?
}

struct TrayContent: View {
    @ObservedObject var model: TrayModel
    private var theme: ResolvedTheme { model.theme }

    var body: some View {
        VStack(spacing: SidebarTrayView.gap) {
            Spacer(minLength: 0)
            ForEach(Array(model.plan.players.enumerated()), id: \.element.id) { i, p in
                let more = i == model.plan.players.count - 1 ? model.plan.morePlayers : []
                MediaPlayerRow(player: p, more: more, library: model.library)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            ForEach(model.plan.downloads) { d in
                SidebarDownloadRow(item: d, library: model.library)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if !model.plan.summary.isEmpty {
                SidebarDownloadSummary(items: model.plan.summary, library: model.library)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, AircMetrics.Sidebar.inset)
        .padding(.bottom, SidebarTrayView.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(AircSpring.row.animation, value: model.plan.players.map(\.id))
        .animation(AircSpring.row.animation, value: model.plan.downloads.map(\.id))
        .testAnchorRoot()
        .aircTheme(theme)
    }
}

// MARK: - Rows

/// The row's plate: a Favorites tile's fill, lighter under the pointer.
private struct TrayPlate: ViewModifier {
    let hovered: Bool
    @Environment(\.aircTheme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(height: SidebarTrayView.rowHeight)
            .background(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous)
                .fill((hovered ? theme.tileHoverFill : theme.tileFill).color))
            .contentShape(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous))
    }
}

/// A 24 pt glyph button with a hover plate.
struct TrayButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    var anchor: String?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? theme.textSecondary.color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: AircRadius.small, style: .continuous)
                    .fill(hovered ? theme.hoverFill.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(anchor ?? "")
    }
}

/// Media Session artwork (the best one that loads), else the site's icon; for a call, the devices it uses.
struct TrayArtwork: View {
    let artwork: [String]
    let pageURL: String
    var size: CGFloat = 26
    var capture: EngineMediaSession.Capture?
    @State private var image: NSImage?
    @State private var loaded: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RemoteFavicon(pageURL: pageURL, size: AircMetrics.Row.favicon).frame(width: size, height: size)
                }
            }
            if let c = capture, c.camera || c.microphone || c.screen {
                // The menu bar's own colours: green for the camera, orange for the microphone.
                Circle().fill(c.camera ? Color(red: 0.20, green: 0.78, blue: 0.35) : Color(red: 1, green: 0.62, blue: 0.04))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: load)
        .onChange(of: artwork) { _, _ in load() }
    }

    private func load() {
        guard let first = artwork.first(where: { $0.hasPrefix("http") || $0.hasPrefix("data:image/") }), first != loaded else {
            if artwork.isEmpty { image = nil; loaded = nil }
            return
        }
        loaded = first
        if first.hasPrefix("data:") {
            image = Self.decodeDataURL(first)
            return
        }
        if let hit = FaviconCache.shared.cached(first) { image = hit; return }
        FaviconCache.shared.load(first) { img in if loaded == first { image = img } }
    }

    static func decodeDataURL(_ s: String) -> NSImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let head = s[..<comma], body = String(s[s.index(after: comma)...])
        let data = head.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        return data.flatMap(NSImage.init(data:))
    }
}

/// A tab playing in the background, or a call: artwork, title and artist, and its controls. A click goes to its tab.
struct MediaPlayerRow: View {
    let player: MediaCenter.Player
    /// Players beyond this row (a menu of them on the "+N" chip).
    let more: [MediaCenter.Player]
    weak var library: MediaLibrary?
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var media: MediaCenter? { library?.media }
    private var s: EngineMediaSession { player.session }

    var body: some View {
        HStack(spacing: 8) {
            TrayArtwork(artwork: s.artwork, pageURL: player.pageURL, capture: player.isCall ? s.capture : nil)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.title).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.text.color).lineLimit(1)
                Text(player.subtitle).aircFont(AircFont.caption).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !more.isEmpty { moreChip }
            if player.isCall { callControls } else { musicControls }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .modifier(TrayPlate(hovered: hovered))
        .onHover { hovered = $0 }
        .onTapGesture { media?.goToTab(player) }
        .help(player.isCall ? "Go to the call" : "Go to the tab")
        .testAnchor("tray.player.\(player.tabID)")
    }

    @ViewBuilder private var musicControls: some View {
        HStack(spacing: 0) {
            if hovered {
                TrayButton(symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: player.muted ? "Unmute Tab" : "Mute Tab",
                           anchor: "tray.mute.\(player.tabID)") { media?.toggleMute(player) }
            }
            if s.playback != .none {
                TrayButton(symbol: s.playback == .playing ? "pause.fill" : "play.fill", help: s.playback == .playing ? "Pause" : "Play",
                           anchor: "tray.play.\(player.tabID)") { media?.togglePlayback(player) }
            }
            if s.actions.contains("nexttrack") {
                TrayButton(symbol: "forward.fill", help: "Next", anchor: "tray.next.\(player.tabID)") { media?.perform("nexttrack", player) }
            }
        }
    }

    @ViewBuilder private var callControls: some View {
        HStack(spacing: 0) {
            if s.actions.contains("togglemicrophone") {
                TrayButton(symbol: s.microphoneOn ? "mic.fill" : "mic.slash.fill", help: s.microphoneOn ? "Mute Microphone" : "Unmute Microphone",
                           tint: s.microphoneOn ? nil : AircColor.destructive.color, anchor: "tray.mic.\(player.tabID)") {
                    media?.perform("togglemicrophone", player)
                }
            }
            if s.actions.contains("togglecamera") {
                TrayButton(symbol: s.cameraOn ? "video.fill" : "video.slash.fill", help: s.cameraOn ? "Turn Camera Off" : "Turn Camera On",
                           tint: s.cameraOn ? nil : AircColor.destructive.color, anchor: "tray.cam.\(player.tabID)") {
                    media?.perform("togglecamera", player)
                }
            }
            if s.actions.contains("hangup") {
                TrayButton(symbol: "phone.down.fill", help: "Leave Call", tint: AircColor.destructive.color, anchor: "tray.leave.\(player.tabID)") {
                    media?.perform("hangup", player)
                }
            }
        }
    }

    private var moreChip: some View {
        Menu {
            ForEach(more) { p in
                Button(p.title + (p.subtitle.isEmpty ? "" : " — " + p.subtitle)) { media?.goToTab(p) }
            }
        } label: {
            Text("+\(more.count)").aircFont(AircFont.micro).foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, 5).frame(height: 16)
                .background(Capsule().fill(theme.hoverFill.color))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(more.count) more playing")
    }
}

/// A download in the sidebar: its file, a progress ring, name and progress. A click opens the Library on Downloads;
/// a finished file drags out to Finder or another app.
struct SidebarDownloadRow: View {
    let item: DownloadCenter.Item
    weak var library: MediaLibrary?
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var d: EngineDownload { item.download }
    private var center: DownloadCenter? { library?.downloads }

    var body: some View {
        HStack(spacing: 8) {
            DownloadGlyph(download: d, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(d.fileName).aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.text.color)
                    .lineLimit(1).truncationMode(.middle)
                Text(d.state == .complete ? "Done · " + DownloadCenter.status(item, host: false) : DownloadCenter.status(item, host: false))
                    .aircFont(AircFont.caption)
                    .foregroundStyle((d.dangerous ? AircColor.downloadWarning : theme.textSecondary).color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovered { controls }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .modifier(TrayPlate(hovered: hovered))
        .onHover { hovered = $0 }
        .onTapGesture {
            if d.dangerous { center?.askAgain(item) } else { library?.showDownloads() }
        }
        .downloadDrag(item, center: center)
        .help(d.dangerous ? "Keep or discard this file" : "Show in Library (⇧⌘L)")
        .testAnchor("tray.download.\(d.id)")
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 0) {
            if d.state == .inProgress, !d.dangerous {
                TrayButton(symbol: d.paused ? "play.fill" : "pause.fill", help: d.paused ? "Resume" : "Pause",
                           anchor: "tray.pause.\(d.id)") { center?.perform(d.paused ? .resume : .pause, item) }
                TrayButton(symbol: "xmark", help: "Cancel Download", anchor: "tray.cancel.\(d.id)") { center?.perform(.cancel, item) }
            } else if d.state == .complete {
                TrayButton(symbol: "magnifyingglass", help: "Show in Finder", anchor: "tray.reveal.\(d.id)") { center?.showInFinder(item) }
            }
        }
    }
}

/// Three or more downloads: one row, one ring for all of them.
struct SidebarDownloadSummary: View {
    let items: [DownloadCenter.Item]
    weak var library: MediaLibrary?
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let running = items.filter { $0.download.state == .inProgress }
        let received = running.reduce(Int64(0)) { $0 + $1.download.received }
        let total = running.allSatisfy { $0.download.total != nil } ? running.reduce(Int64(0)) { $0 + ($1.download.total ?? 0) } : nil
        let speed = running.compactMap(\.speed).reduce(0, +)
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textSecondary.color)
                ProgressRing(fraction: total.map { $0 > 0 ? Double(received) / Double($0) : 0 }, paused: false, size: 22)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(items.count) downloads").aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.text.color)
                Text(summaryText(running.count, received, total, speed)).aircFont(AircFont.caption)
                    .foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .modifier(TrayPlate(hovered: hovered))
        .onHover { hovered = $0 }
        .onTapGesture { library?.showDownloads() }
        .help("Show in Library (⇧⌘L)")
        .testAnchor("tray.downloads")
    }

    private func summaryText(_ running: Int, _ received: Int64, _ total: Int64?, _ speed: Double) -> String {
        guard running > 0 else { return "Done" }
        var s = total.map { DownloadCenter.progressText(received, of: $0) } ?? DownloadCenter.size(received)
        if let total, speed > 1 { s += " · " + DownloadCenter.timeLeft(Double(total - received) / speed) }
        return s
    }
}

/// The file's icon in a progress ring (a warning for a risky file).
struct DownloadGlyph: View {
    let download: EngineDownload
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if download.dangerous {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(AircColor.downloadWarning.color)
            } else {
                Image(nsImage: DownloadCenter.icon(download)).resizable().interpolation(.high)
                    .frame(width: download.isActive ? size - 9 : size - 2, height: download.isActive ? size - 9 : size - 2)
                    .opacity(download.state == .cancelled || download.state == .interrupted ? 0.5 : 1)
            }
            if download.isActive, !download.dangerous {
                ProgressRing(fraction: download.fraction, paused: download.paused, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Arc's ring: the track at the hover fill, progress in the accent (secondary ink while paused). An unknown size shows
/// a still quarter, not a spinner (nothing animates while a download waits on the network).
struct ProgressRing: View {
    let fraction: Double?
    let paused: Bool
    var size: CGFloat = 26
    @Environment(\.aircTheme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(theme.hoverFill.color, lineWidth: 2.2)
            Circle().trim(from: 0, to: max(0.02, fraction ?? 0.25))
                .stroke((paused ? theme.textTertiary : theme.accent).color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: fraction)
        }
        .frame(width: size - 2, height: size - 2)
    }
}

extension View {
    /// A finished file drags out as itself (Finder copies it, Mail attaches it).
    @ViewBuilder func downloadDrag(_ item: DownloadCenter.Item, center: DownloadCenter?) -> some View {
        if item.download.state == .complete, let url = center?.file(item) {
            onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            self
        }
    }
}

extension AircColor {
    /// A risky download's ink: amber, apart from the red of destructive buttons.
    static let downloadWarning = AircColor(0xD97706)
}

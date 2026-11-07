// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import SwiftUI

// PW-1, what a private window shares with the main one (PrivateWindow.swift): the find bar (⌘F ⌘G ⇧⌘G), the page's
// shortcuts first (CB-3: KeyMonitor's arbitration, with this window's commands), and a list of its downloads.

// MARK: - Find (⌘F)

extension PrivateWindowController {
    /// ⌘F: the main window's find field (FindBarView) over this window's page.
    func showFind() {
        guard shownPage != nil else { return NSSound.beep() }
        if let bar = findBar {
            window.makeFirstResponder(bar.field)
            bar.field.currentEditor()?.selectAll(nil)
            return
        }
        let bar = FindBarView(palette: palette)
        bar.onFind = { [weak self] text, forward in self?.find(text, forward: forward) }
        bar.onClose = { [weak self] in self?.closeFind(refocusPage: true) }
        #if canImport(AircCore)
        (app?.engine as? ChromiumEngine)?.findStateDidChange = FindBarView.routeFindState
        #endif
        findBar = bar
        root.addSubview(bar, positioned: .below, relativeTo: toast)
        layoutFindBar()
        bar.layer?.fade(from: 0, to: 1, duration: 0.12)
        window.makeFirstResponder(bar.field)
    }

    func layoutFindBar() {
        guard let bar = findBar else { return }
        let s = FindBarView.size, page = card.frame
        bar.frame = NSRect(x: page.maxX - s.width - 12, y: page.minY + 12, width: s.width, height: s.height)
    }

    /// ⌘G / ⇧⌘G.
    func findAgain(forward: Bool) {
        guard let bar = findBar, !bar.field.stringValue.isEmpty else { return showFind() }
        bar.find(forward: forward)
    }

    private func find(_ text: String, forward: Bool) {
        guard let page = shownPage else { return }
        guard !text.isEmpty else {
            page.stopFinding()
            findBar?.setStatus(found: nil, matches: nil)
            return
        }
        page.find(text, forward: forward) { [weak self] found, matches in self?.findBar?.setStatus(found: found, matches: matches) }
    }

    /// Esc, the ✕, or another tab shown.
    func closeFind(refocusPage: Bool) {
        guard let bar = findBar else { return }
        findBar = nil
        if let page = shownPage {
            page.stopFinding()
            if refocusPage { page.focus() }
        }
        bar.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bar.removeFromSuperview() }
    }
}

// MARK: - The page's shortcuts first (CB-3)

extension PrivateWindowController {
    /// The shown page, when it has the keyboard.
    var focusedPage: EngineTab? {
        guard let page = shownPage, let r = window.firstResponder as? NSView, r === page.view || r.isDescendant(of: page.view) else { return nil }
        return page
    }

    /// The key monitor's path: a key this window binds goes to its page first when the main window's would (⌘ and ⇧⌘
    /// keys but Chrome's reserved ⌘T ⌘W ⌘N ⌘Q; ⌥ and ⌃ keys stay the browser's), and the command runs only if the page
    /// doesn't use it. ⌘Z, ⇧⌘Z and Paste and Match Style aren't this window's: AppKit gives them to the field or page
    /// with the keyboard, then to the Edit menu's undo:, redo: and pasteAndMatchStyle: on it.
    func handleKeyPageFirst(_ event: NSEvent) -> Bool {
        guard let (key, mods) = Self.normalizedKey(event), let run = action(forTyped: key, modifiers: mods) else { return false }
        let cmd = CommandMenus.all.first { $0.key.lowercased() == key && $0.modifiers == mods } ?? BrowserCommand("", key, mods) { _ in }
        if KeyMonitor.offerToPage(cmd, page: focusedPage, engine: app?.engine, window: window, run: run) {
            KeyMonitor.deliverToPage(event, in: window)
            return true
        }
        run()
        return true
    }
}

// MARK: - Downloads

/// One private session's downloads (its windows share it, like the session): the engine's rows for the session's
/// off-the-record profile (Chromium) or non-persistent store (WebKit), newest first. Files go to the Downloads folder as
/// any download does; this list lives in memory only and goes with the session, and the main window's Library never
/// sees it (its DownloadCenter observes the Space profiles only). Nothing here is recorded, not even in telemetry.
final class PrivateDownloads: ObservableObject {
    @Published private(set) var items: [DownloadCenter.Item] = []
    let engine: EngineDownloads
    let profile: EngineProfile
    private var byID: [String: DownloadCenter.Item] = [:]
    private var lastSample: [String: (at: CFTimeInterval, bytes: Int64)] = [:]
    private var publishQueued = false

    init(engine: EngineDownloads, profile: EngineProfile) {
        self.engine = engine
        self.profile = profile
        for d in engine.downloadItems(in: profile) { update(d) }
        engine.observeDownloadItems(in: profile) { [weak self] d in self?.update(d) }
        publish()
    }

    /// The session ended.
    func stop() {
        engine.observeDownloadItems(in: profile, nil)
        byID = [:]
        lastSample = [:]
        items = []
    }

    var runningCount: Int { byID.values.filter { $0.download.state == .inProgress && !$0.download.dangerous }.count }

    private func update(_ d: EngineDownload) {
        if d.removed {
            byID[d.id] = nil
            lastSample[d.id] = nil
            return publishSoon()
        }
        var item = byID[d.id] ?? DownloadCenter.Item(profileID: "private", download: d)
        item.download = d
        let now = CACurrentMediaTime()
        if d.state == .inProgress, !d.paused, let s = lastSample[d.id], d.received > s.bytes, now - s.at > 0.05 {
            let instant = Double(d.received - s.bytes) / (now - s.at)
            item.speed = item.speed.map { 0.75 * $0 + 0.25 * instant } ?? instant
            lastSample[d.id] = (now, d.received)
        } else if lastSample[d.id] == nil || d.paused || d.state != .inProgress {
            lastSample[d.id] = (now, d.received)
            if d.paused || d.state != .inProgress { item.speed = nil }
        }
        byID[d.id] = item
        publishSoon()
    }

    /// At most ten times a second.
    private func publishSoon() {
        guard !publishQueued else { return }
        publishQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.publishQueued = false
            self.publish()
        }
    }

    func publish() {
        let all = byID.values.sorted { a, b in
            let x = a.download.startTime ?? .distantPast, y = b.download.startTime ?? .distantPast
            return x != y ? x > y : a.id > b.id
        }
        if all != items { items = all }
    }

    @discardableResult
    func perform(_ action: EngineDownloadAction, _ item: DownloadCenter.Item) -> Bool {
        engine.performDownloadAction(action, id: item.download.id, in: profile)
    }

    func file(_ item: DownloadCenter.Item) -> URL? {
        guard item.download.state == .complete, !item.download.dangerous else { return nil }
        return engine.downloadedFile(item.download.id, in: profile)
    }

    /// A finished file opens in its app (scripted runs record it: DownloadCenter.interceptOpen).
    func open(_ item: DownloadCenter.Item) {
        if item.download.state == .complete, let intercept = DownloadCenter.interceptOpen, intercept(item) { return }
        perform(.open, item)
    }

    func showInFinder(_ item: DownloadCenter.Item) {
        if let url = file(item) {
            DownloadCenter.reveal([url])
        } else if let path = item.download.path {
            DownloadCenter.reveal([URL(fileURLWithPath: path).deletingLastPathComponent()])
        }
    }
}

extension PrivateWindowController {
    /// The session's list (PrivateBrowsing keeps one per session).
    var downloads: PrivateDownloads? { PrivateBrowsing.shared.downloads(of: profileID) }

    /// Connects the sidebar's list to the session's downloads (once, when the window opens).
    func connectDownloads() {
        guard let d = downloads else { return }
        sidebar.downloads.connect(d, palette: palette) { [weak self] item in self?.askAboutDangerous(item) }
        downloadsWatch = d.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
            guard let self else { return }
            self.sidebar.downloadRows = items.count
        }
    }

    /// A risky file: Keep (only after the person says so) or Discard, as a sheet on this window.
    func askAboutDangerous(_ item: DownloadCenter.Item) {
        guard let d = downloads, item.download.dangerous, item.download.state == .inProgress, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Keep “\(item.download.fileName)”?"
        alert.informativeText = DownloadCenter.dangerText(item.download)
        alert.addButton(withTitle: "Discard")
        if item.download.canKeep { alert.addButton(withTitle: "Keep") }
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: d.perform(.discard, item)
            case .alertSecondButtonReturn where item.download.canKeep: d.perform(.keep, item)
            default: break
            }
        }
    }

    /// Closing the session's last window cancels its running downloads: ask first, as a sheet on this window.
    func askBeforeClosing(count: Int, _ answer: @escaping (Bool) -> Void) {
        guard window.attachedSheet == nil else { return answer(false) }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Cancel the download?" : "Cancel \(count) downloads?"
        alert.informativeText = "A private window’s downloads stop when its last window closes."
        alert.addButton(withTitle: count == 1 ? "Cancel Download" : "Cancel Downloads")
        alert.addButton(withTitle: "Keep Window Open")
        alert.beginSheetModal(for: window) { response in answer(response == .alertFirstButtonReturn) }
    }
}

/// The sidebar's downloads, above its note (as the main sidebar's tray sits above its footer): every download of the
/// session, newest first, 40 pt rows 6 pt apart, three in view and the rest a scroll away. With none it takes no space.
final class PrivateDownloadsView: NSView {
    static let rowHeight: CGFloat = 40
    static let gap: CGFloat = 6
    static let maxRows = 3
    private var host: AircFirstClickHostingView<PrivateDownloadsList>?
    var hostingView: NSView? { host }

    override var isFlipped: Bool { true }

    func connect(_ model: PrivateDownloads, palette: Palette, onDangerous: @escaping (DownloadCenter.Item) -> Void) {
        host?.removeFromSuperview()
        let h = AircFirstClickHostingView(rootView: PrivateDownloadsList(model: model, theme: palette.resolved, onDangerous: onDangerous))
        h.safeAreaRegions = []
        addSubview(h)
        host = h
        needsLayout = true
    }

    /// The height for `rows` downloads.
    static func height(rows: Int) -> CGFloat {
        let n = min(rows, maxRows)
        return n == 0 ? 0 : CGFloat(n) * rowHeight + CGFloat(n - 1) * gap
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
    }
}

struct PrivateDownloadsList: View {
    @ObservedObject var model: PrivateDownloads
    let theme: ResolvedTheme
    let onDangerous: (DownloadCenter.Item) -> Void

    var body: some View {
        Group {
            // A scroll view only when there's more than fits: it would take a background window's first click.
            if model.items.count > PrivateDownloadsView.maxRows {
                ScrollView(.vertical, showsIndicators: true) { rows }
            } else {
                rows
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.items.map(\.id))
        .aircTheme(theme)
        .testAnchorRoot()
    }

    private var rows: some View {
        VStack(spacing: PrivateDownloadsView.gap) {
            ForEach(model.items) { item in
                PrivateDownloadRow(item: item, model: model, onDangerous: onDangerous)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A download: its file in a progress ring, name and progress; ⏸ and ✕ while it runs, 🔍 when done. A click opens a
/// finished file (there's no Library here to show it in) or asks about a risky one.
struct PrivateDownloadRow: View {
    let item: DownloadCenter.Item
    let model: PrivateDownloads
    let onDangerous: (DownloadCenter.Item) -> Void
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme

    private var d: EngineDownload { item.download }

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
        .frame(height: PrivateDownloadsView.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous)
            .fill((hovered ? theme.tileHoverFill : theme.tileFill).color))
        .contentShape(RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture {
            if d.dangerous { onDangerous(item) } else if d.state == .complete { model.open(item) }
        }
        .help(d.dangerous ? "Keep or discard this file" : d.state == .complete ? "Open" : d.fileName)
        .testAnchor("private.download.\(d.id)")
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 0) {
            if d.state == .inProgress, !d.dangerous {
                TrayButton(symbol: d.paused ? "play.fill" : "pause.fill", help: d.paused ? "Resume" : "Pause") {
                    model.perform(d.paused ? .resume : .pause, item)
                }
                TrayButton(symbol: "xmark", help: "Cancel Download") { model.perform(.cancel, item) }
            } else if d.state == .complete {
                TrayButton(symbol: "magnifyingglass", help: "Show in Finder") { model.showInFinder(item) }
            } else if d.state == .interrupted, d.canResume {
                TrayButton(symbol: "arrow.clockwise", help: "Try Again") { model.perform(.retry, item) }
            }
        }
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine
import ImageIO
import SwiftUI

/// Small pictures of the agent's pages for the Recent tasks cards and the task view's "Opened …" steps (asidepass).
/// One copy when a step opens a page (after it has had time to paint) and one when a run ends. Nothing runs while no
/// agent works.
/// agentrecall: kept as small JPEGs per task (AircKit's AgentTaskPictureStore, `<data folder>/Agent/Tasks/Pictures`,
/// capped, deleted with the task), so a finished task still shows them after a relaunch; read back lazily, off the main
/// thread, the first time a card or step asks. Never written for a private window's task.
final class AgentTaskThumbs: ObservableObject {
    static let shared = AgentTaskThumbs()

    struct Shot {
        let image: CGImage; let title: String; let host: String?
        /// agentparkcpu: the page's address and how much it shows (`detail`), so a later copy of the same page caught
        /// mid-paint never replaces a good one (nil / 0: unknown, e.g. read from disk).
        var url: URL? = nil
        var detail: Double = 0
    }
    /// By task id: the agent's last page.
    private(set) var tasks: [String: Shot] = [:]
    /// By step key (the step's id): the page an "Opening …" step opened.
    private(set) var steps: [String: Shot] = [:]
    @Published private(set) var revision = 0
    private var seen = Set<UUID>()
    /// agentparallel: each task's run, followed from when AgentTaskCenter makes it.
    private var subs: [ObjectIdentifier: [AnyCancellable]] = [:]
    private var wasActive: [ObjectIdentifier: Bool] = [:]
    #if AIRC_TESTING
    /// Checks: copies a richer picture of the same page kept out (task/step key), and every copy made.
    private(set) var keptOver: [String] = []
    private(set) var captureLog: [String] = []
    #endif
    static let maxPixels = CGSize(width: 720, height: 450)
    static let keep = 40
    let store = AgentTaskPictureStore(folder: AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks/Pictures", isDirectory: true))
    /// Disk reads and writes, one at a time, off the main thread.
    private let disk = DispatchQueue(label: "org.airc.agent-task-pictures", qos: .utility)
    /// "task/key" already looked for on disk (found or not): asked once per launch.
    private var looked = Set<String>()
    /// Tasks deleted since launch: a late write or read for one is dropped.
    private var forgotten = Set<String>()
    #if AIRC_TESTING
    /// Checks: pictures written (task/key) and refused for a private window's task.
    private(set) var writes: [String] = []
    private(set) var privateSkips = 0
    #endif

    private init() {}

    func attach(_ run: AgentRunCenter) {
        let key = ObjectIdentifier(run)
        guard subs[key] == nil else { return }
        subs[key] = [
            run.$steps.sink { [weak self, weak run] s in DispatchQueue.main.async { if let run { self?.stepsChanged(s, run) } } },
            run.$state.sink { [weak self, weak run] s in DispatchQueue.main.async { if let run { self?.stateChanged(s, run) } } },
        ]
    }

    func detach(_ run: AgentRunCenter) {
        subs[ObjectIdentifier(run)] = nil
        wasActive[ObjectIdentifier(run)] = nil
    }

    /// The task's card picture: in memory, else read from disk (nil now; `revision` changes once it's there).
    func task(_ id: String) -> Shot? {
        if let s = tasks[id] { return s }
        load(task: id, key: AgentTaskPictureStore.card)
        return nil
    }

    /// A step's picture by its key (the live step's id; a record line's `key`).
    func step(_ key: String, task: String?) -> Shot? {
        if let s = steps[key] { return s }
        if let task { load(task: task, key: key) }
        return nil
    }

    private func load(task: String, key: String) {
        let tag = task + "/" + key
        guard !forgotten.contains(task), looked.insert(tag).inserted else { return }
        let store = store
        disk.async { [weak self] in
            // Decoded here, off the main thread, and drawn into a plain RGBA bitmap: the same kind of picture as a live
            // copy (a JPEG straight from ImageIO drew as an empty tile in the task view after a relaunch).
            guard let data = store.load(task: task, key: key), let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let image = Self.bitmap(decoded) else { return }
            DispatchQueue.main.async {
                guard let self, !self.forgotten.contains(task) else { return }
                let shot = Shot(image: image, title: "", host: nil)
                if key == AgentTaskPictureStore.card { if self.tasks[task] == nil { self.tasks[task] = shot } }
                else if self.steps[key] == nil { self.steps[key] = shot }
                self.trim()
                self.revision += 1
            }
        }
    }

    private func stepsChanged(_ all: [AgentStep], _ run: AgentRunCenter) {
        if all.isEmpty { return }
        // agentparkcpu: the answer is in while the page is still the agent's (the run's end comes a hop later, when it
        // may already be on its way back to the person's window): the card's picture now; the end copies once more.
        for s in all where s.kind == .final && !seen.contains(s.id) {
            seen.insert(s.id)
            capture(step: nil, run: run)
        }
        for s in all where s.kind == .action && !seen.contains(s.id) {
            seen.insert(s.id)
            guard s.text.hasPrefix("Opening") else { continue }
            // The page needs a moment to paint; the step's own row shows the site's icon until then.
            let id = s.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak run] in if let run { self?.capture(step: id, run: run) } }
        }
    }

    private func stateChanged(_ s: AgentRunCenter.State, _ run: AgentRunCenter) {
        let key = ObjectIdentifier(run)
        defer { wasActive[key] = s.isActive }
        if wasActive[key] == true, !s.isActive { capture(step: nil, run: run) }
    }

    /// Copies the agent's shown page once (both engines' Watch frame copy, scaled down), and keeps it as a JPEG.
    func capture(step: UUID?, run: AgentRunCenter) {
        guard let wid = run.runWindowID, let w = AgentCenter.shared.windows[wid], let tab = w.activeTab,
              let task = AgentTaskRecorder.shared.recordID(run) else { return }
        let title = tab.title
        let url = tab.url
        let host = url?.host.map(AgentPaneTimeline.trimmed)
        let privateWindow = run.privateWindow
        #if AIRC_TESTING
        let parked = AgentMainView.shared.entry(tab).flatMap { e in e.window.map { $0.isParked(tab) } }
        let asked = CACurrentMediaTime()
        #endif
        w.driver.watchFrame(tab, maxPixels: Self.maxPixels) { [weak self] picture in
            #if AIRC_TESTING
            self?.captureLog.append("task \(task) \(step == nil ? "card" : "step") \(url?.path ?? "-") parked \(parked.map { "\($0)" } ?? "not hosted") view \(tab.view.window.map { NSStringFromClass(type(of: $0)) } ?? "no window") \(Int((CACurrentMediaTime() - asked) * 1000)) ms: \(picture.map { "\($0.width)x\($0.height) detail \(String(format: "%.2f", Self.detail($0))) blank \(Self.isBlank($0))" } ?? "none")")
            #endif
            // A frame copied before the page painted is one colour (black or white): keep the site's tile instead.
            guard let self, let picture, !Self.isBlank(picture) else { return }
            let shot = Shot(image: picture, title: title, host: host, url: url, detail: Self.detail(picture))
            // A copy caught mid-paint (the page's background, its boxes without their text) never replaces a good
            // picture of the same page: the last good frame stays (aidemo4's empty "Compare noise-cancelling…" card).
            let keepCard = self.tasks[task].map { !Self.replaces(shot, $0) } ?? false
            let keepStep = step.flatMap { self.steps[$0.uuidString] }.map { !Self.replaces(shot, $0) } ?? false
            #if AIRC_TESTING
            if keepCard { self.keptOver.append(task) }
            if keepStep, let step { self.keptOver.append(step.uuidString) }
            #endif
            if keepCard && (step == nil || keepStep) { return }
            if let step, !keepStep { self.steps[step.uuidString] = shot }
            if !keepCard { self.tasks[task] = shot }
            self.trim(keepTask: task, keepStep: step?.uuidString)
            self.revision += 1
            // Never on disk for a private window's task.
            guard !privateWindow else {
                #if AIRC_TESTING
                self.privateSkips += 1
                #endif
                return
            }
            self.write(picture, task: task, keys: (keepCard ? [] : [AgentTaskPictureStore.card]) + (step.flatMap { keepStep ? nil : [$0.uuidString] } ?? []))
        }
    }

    /// On the disk queue, in order: a delete (`forget`) queued after this write removes what it wrote, and nothing is
    /// queued for a task already deleted.
    private func write(_ picture: CGImage, task: String, keys: [String]) {
        guard !forgotten.contains(task) else { return }
        let store = store
        disk.async { [weak self] in
            guard let jpeg = Self.jpeg(picture, maxBytes: store.maxPictureBytes) else { return }
            var written: [String] = []
            for k in keys where store.save(jpeg, task: task, key: k) { written.append(task + "/" + k) }
            #if AIRC_TESTING
            DispatchQueue.main.async { self?.writes += written }
            #else
            _ = written
            #endif
        }
    }

    /// JPEG at a quality that fits the store's per-picture cap (two tries, then smaller).
    static func jpeg(_ image: CGImage, maxBytes: Int) -> Data? {
        var source = image
        for attempt in 0..<4 {
            let quality = [0.62, 0.45, 0.45, 0.4][attempt]
            if attempt == 2, let half = scaled(image, by: 0.5) { source = half }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if data.length <= maxBytes { return data as Data }
        }
        return nil
    }

    /// `image` redrawn into an 8-bit sRGB RGBA bitmap.
    static func bitmap(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func scaled(_ image: CGImage, by f: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(image.width) * f)), h = max(1, Int(CGFloat(image.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Memory stays small: the newest few dozen pictures (the files stay on disk).
    private func trim(keepTask: String? = nil, keepStep: String? = nil) {
        // What's dropped from memory may be read from disk again.
        if steps.count > Self.keep * 4 { steps = keepStep.flatMap { k in steps[k].map { [k: $0] } } ?? [:]; looked.removeAll() }
        if tasks.count > Self.keep { tasks = keepTask.flatMap { k in tasks[k].map { [k: $0] } } ?? [:]; looked.removeAll() }
    }

    /// A deleted task: its pictures go from memory and disk.
    func forget(task: String) {
        forgotten.insert(task)
        tasks[task] = nil
        let store = store
        disk.async { store.delete(task: task) }
        revision += 1
    }

    /// At launch: the folders of tasks that no longer exist go.
    func prune(keeping ids: Set<String>) {
        let store = store
        disk.async { store.prune(keeping: ids) }
    }

    /// Whether a picture is (nearly) one colour: drawn into 8×8 pixels, every channel within 6 of the first pixel.
    /// Whether a new copy may replace `old`: always for another page (or an old one of unknown detail); for the same
    /// page only when it shows at least a third as much (a copy with far less is the page caught mid-paint).
    static func replaces(_ new: Shot, _ old: Shot) -> Bool {
        guard let u = new.url, u == old.url, old.detail > 0 else { return true }
        return new.detail >= old.detail / 3
    }

    /// How much a picture shows: the mean brightness step between neighbouring pixels of a 32×32 copy (text, edges
    /// and pictures count; a flat background or empty boxes come out near 0).
    static func detail(_ image: CGImage) -> Double {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0
        for y in 0..<n {
            for x in 0..<n {
                let v = Int(px[y * n + x])
                if x + 1 < n { sum += abs(v - Int(px[y * n + x + 1])) }
                if y + 1 < n { sum += abs(v - Int(px[(y + 1) * n + x])) }
            }
        }
        return Double(sum) / Double(2 * n * (n - 1))
    }

    static func isBlank(_ image: CGImage) -> Bool {
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return false }
        for i in stride(from: 4, to: px.count, by: 4) {
            for c in 0..<3 where abs(Int(px[i + c]) - Int(px[c])) > 6 { return false }
        }
        return true
    }

    #if AIRC_TESTING
    /// Checks and marketing shots: a picture for a made-up task or step.
    func setForTesting(task: String?, step: UUID?, image: CGImage, title: String, host: String?) {
        let shot = Shot(image: image, title: title, host: host)
        if let task { tasks[task] = shot }
        if let step { steps[step.uuidString] = shot }
        revision += 1
    }

    /// Checks: whether the task's pictures are in memory now (a relaunch starts with none).
    func inMemory(task: String) -> Bool { tasks[task] != nil }

    /// Checks: waits until every queued disk write has finished.
    func flushForTesting(_ done: @escaping () -> Void) { disk.async { DispatchQueue.main.async(execute: done) } }
    #endif
}

/// "Recent tasks": the newest tasks of this Space as cards, the running ones first (Command Bar Ask mode).
struct AgentRecentTasks: View {
    let spaceID: String
    var limit = 3
    let open: (AgentTaskRecord) -> Void
    var showAll: (() -> Void)?
    @ObservedObject private var recorder = AgentTaskRecorder.shared
    @Environment(\.aircTheme) private var theme

    var tasks: [AgentTaskRecord] {
        Array(recorder.tasks.filter { $0.spaceID == spaceID || $0.spaceID.isEmpty }.prefix(limit))
    }

    var body: some View {
        let list = tasks
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent tasks").aircFont(AircFont.callout.weight(.semibold)).foregroundStyle(theme.surfaceText.color)
                    Spacer()
                    if let showAll {
                        Button("Show all", action: showAll).buttonStyle(.plain).aircFont(AircFont.caption)
                            .foregroundStyle(theme.surfaceTextTertiary.color).testAnchor("agentask.recent.all")
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(list) { t in
                        AgentTaskCard(task: t) { open(t) }.frame(maxWidth: .infinity)
                    }
                    // Keep card widths steady with fewer than `limit` tasks.
                    ForEach(0..<max(0, limit - list.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
            .testAnchor("agentask.recent")
        }
    }
}

/// One task card: status line ("Working for 3m 48s" / "an hour ago"), title, the last steps or the answer's start, and
/// the agent's page (live while it works, the last copy after, else the site's icon on a tile).
struct AgentTaskCard: View {
    let task: AgentTaskRecord
    let open: () -> Void
    @ObservedObject private var thumbs = AgentTaskThumbs.shared
    /// agentparallel: every task's card follows its own run.
    @ObservedObject private var tasks = AgentTaskCenter.shared
    private var run: AgentRunCenter? { tasks.run(task: task.id) }
    @State private var hovered = false
    @Environment(\.aircTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { run?.isBusy == true }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        statusLine
                        Spacer(minLength: 4)
                        if task.unread { Circle().fill(theme.accent.color).frame(width: 7, height: 7).testAnchor("agentask.card.unread") }
                        if task.status == .waiting { Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    }
                    Text(task.title).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.surfaceText.color)
                        .lineLimit(1).truncationMode(.tail)
                    detail.frame(height: 50, alignment: .topLeading)
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                picture
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 11, bottomTrailingRadius: 11, topTrailingRadius: 6, style: .continuous))
                    .padding([.horizontal, .bottom], 5)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovered ? theme.surfaceText.color.opacity(0.16) : theme.surfaceBorder.color))
            .shadow(color: .black.opacity(hovered ? (theme.isDark ? 0.35 : 0.08) : 0), radius: 10, y: 3)
            .scaleEffect(hovered && !reduceMotion ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { hovered = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.title)
        .accessibilityValue(statusWords(now: Date()) + (task.unread ? ", unread" : ""))
        .accessibilityAddTraits(.isButton)
        .testAnchor("agentask.card")
        .testAnchor("agentask.card.\(task.id)")
    }

    @ViewBuilder private var statusLine: some View {
        if live || task.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(statusWords(now: ctx.date)).monospacedDigit()
            }
            .aircFont(AircFont.caption).foregroundStyle(theme.accentText.color)
            .testAnchor("agentask.card.working")
        } else {
            Text(statusWords(now: Date())).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
        }
    }

    func statusWords(now: Date) -> String {
        switch task.status {
        case .running, .takenOver:
            let start = live ? (run?.startedAt ?? task.createdAt) : task.createdAt
            return "Working for " + AgentPaneItem.duration(now.timeIntervalSince(start))
        case .waiting: return "Waiting for your OK"
        case .failed: return "Failed · " + Self.ago(task.updatedAt, now: now)
        case .stopped: return "Stopped · " + Self.ago(task.updatedAt, now: now)
        case .done: return Self.ago(task.endedAt ?? task.updatedAt, now: now)
        case .queued: return "Queued"
        }
    }

    /// "just now", "5 min ago", "an hour ago", "3 hours ago", "yesterday", "4 days ago".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 7200 { return "an hour ago" }
        if s < 86400 { return "\(Int(s / 3600)) hours ago" }
        if s < 2 * 86400 { return "yesterday" }
        return "\(Int(s / 86400)) days ago"
    }

    @ViewBuilder private var detail: some View {
        let steps = task.lastSteps(3)
        if (task.status == .running || task.status == .waiting || task.status == .takenOver || task.answerHead == nil), !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 6) {
                        AgentTaskStepGlyph(caption: s.text, host: s.host, size: 11)
                        Text(s.text).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        } else if let a = task.answerHead ?? task.answer {
            Text(a).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(task.provider).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
        }
    }

    @ViewBuilder private var picture: some View {
        let _ = thumbs.revision
        if live, let run, run.runWindowID != nil {
            AgentPaneLivePicture(run: run).allowsHitTesting(false).testAnchor("agentask.card.live")
        } else if let shot = thumbs.task(task.id) {
            // The top of the page (its header), not its middle: a .fill picture taller than the tile makes a flexible
            // frame take the picture's size, so its alignment did nothing and the tile showed the page's vertical middle,
            // which for a short page is its bare background (aidemo4's empty "Compare noise-cancelling…" card). Laid over
            // a clear tile-sized view instead, aligned to its top.
            Color.clear.overlay(alignment: .top) {
                Image(decorative: shot.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
            .clipped()
            .testAnchor("agentask.card.thumb")
            .testAnchor("agentask.card.thumb.\(task.id)")
        } else {
            AgentTaskSiteTile(host: task.sites.last)
        }
    }
}

/// No picture yet: the task's last site on a soft tile.
struct AgentTaskSiteTile: View {
    let host: String?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.tileFill.color, theme.tileFill.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                AgentPaneSiteIcon(host: host, size: 22)
                if let host { Text(host).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1) }
            }
        }
    }
}

/// A step's leading glyph: the site's icon for page steps, a symbol for the rest (sign-in, typing, reading).
struct AgentTaskStepGlyph: View {
    let caption: String
    let host: String?
    var size: CGFloat = 14
    @Environment(\.aircTheme) private var theme

    var body: some View {
        if let symbol = Self.symbol(caption) {
            Image(systemName: symbol).font(.system(size: size * 0.82, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
                .frame(width: size, height: size)
        } else {
            AgentPaneSiteIcon(host: host, size: size)
        }
    }

    static func symbol(_ caption: String) -> String? {
        if caption.hasPrefix("Opening") { return nil }
        if caption.hasPrefix("Filling a saved login") || caption.hasPrefix("Signing in") { return "key" }
        if caption.hasPrefix("Typing") || caption.hasPrefix("Pressing") { return "keyboard" }
        if caption.hasPrefix("Clicking") { return "cursorarrow.click" }
        if caption.hasPrefix("Read") || caption.hasPrefix("Looking") { return "doc.text.magnifyingglass" }
        if caption.hasPrefix("Finding") { return "magnifyingglass" }
        if caption.hasPrefix("Scrolling") { return "arrow.up.and.down" }
        if caption.hasPrefix("Waiting") { return "hourglass" }
        if caption.hasPrefix("Switching tabs") { return "square.on.square" }
        if caption.hasPrefix("Searched your history") || caption.hasPrefix("Searching your history") || caption.hasPrefix("Couldn't search your history") {
            return "clock.arrow.circlepath"
        }
        return nil
    }
}

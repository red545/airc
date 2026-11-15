// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// easelall (parity N08): Arc's Library card "Your Easels are yours to keep" › Export All Easels. Every Easel on this
// Mac as a web page, in one ZIP (AircKit EaselArchive: a list page, a README with the export log, and each Easel's
// folder exactly as Export as Web Page… writes it). Arc's flow: a save panel ("Save an archive of all your Easels as
// web pages you can open anywhere.", Export, named "Airc Easels - <date>"), a sheet while it works ("Saving your
// Easels…", "Gathering your Easels…", then "<n> of <total>" and the Easel being packed, Cancel), then the result,
// here a toast with Show in Finder (Arc: "Your Easels are saved" / "<n> of <total> Easels saved").
// The work runs off the main thread: each Easel is read, made public (its pictures read and converted) and written to
// the ZIP on disk one after another, so neither the window nor memory notices how many there are.

enum EaselExportAll {
    /// The save panel open now, and the export running (the checks drive and wait for them).
    private(set) static weak var panel: NSSavePanel?
    private(set) static var job: Job?
    /// The progress sheet while it shows.
    private(set) static weak var progressWindow: NSWindow?
    /// The last export's file and what it holds (the checks read it).
    private(set) static var last: Result?

    struct Result {
        var url: URL
        var entries: [EaselArchive.Entry]
        var ok: Bool
        var cancelled: Bool
        var saved: Int { entries.filter(\.isSaved).count }
        /// The Easels that should be in it: saved or failed, not the empty ones.
        var total: Int { entries.filter { $0.outcome != .empty }.count }
    }

    /// Library › Easels › Export All Easels: the save panel over `c`'s window, then the export.
    static func run(in c: WindowController) {
        guard job == nil, c.window.attachedSheet == nil else { return NSSound.beep() }
        EaselCenter.shared.summaries { [weak c] list in
            guard let c else { return }
            let easels = list.filter { $0.blockCount > 0 }
            guard !easels.isEmpty else { return c.showToast("There are no Easels to export yet") }
            let p = NSSavePanel()
            // Arc's save panel for every Easel.
            p.title = "Export All Easels"
            p.message = "Save an archive of all your Easels as web pages you can open anywhere."
            p.prompt = "Export"
            p.allowedContentTypes = [.zip]
            p.nameFieldStringValue = EaselArchive.name() + ".zip"
            p.isExtensionHidden = false
            p.canCreateDirectories = true
            panel = p
            p.beginSheetModal(for: c.window) { [weak c] r in
                guard let c, r == .OK, let url = p.url else { return }
                // The panel is still leaving its sheet: the progress sheet goes up after it.
                DispatchQueue.main.async { start(easels, to: url, in: c) }
            }
        }
    }

    /// The export of `list` to `url` with its progress sheet over `c`'s window and the toast after (the checks call it
    /// without the panel).
    @discardableResult
    static func start(_ list: [EaselFiles.Summary], to url: URL, in c: WindowController, done: ((Result) -> Void)? = nil) -> Job? {
        guard job == nil else { NSSound.beep(); return nil }
        let j = Job(list: list, url: url)
        job = j
        let sheet = ProgressSheet(job: j)
        progressWindow = sheet.window
        if c.window.attachedSheet == nil { c.window.beginSheet(sheet.window) }
        j.run { result in
            if sheet.window.sheetParent != nil { c.window.endSheet(sheet.window) }
            sheet.window.orderOut(nil)
            job = nil
            last = result
            if !result.cancelled {
                if !result.ok {
                    c.showToast("Airc couldn’t finish saving your Easels. Please try again.")
                } else {
                    let text = result.saved == result.total ? "Your Easels are saved" : "\(result.saved) of \(result.total) Easels saved"
                    c.showActionToast(text, action: (title: "Show in Finder", run: { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }))
                }
            }
            done?(result)
        }
        return j
    }

    /// One export: its progress (main thread), and Cancel.
    final class Job: ObservableObject {
        let list: [EaselFiles.Summary]
        let url: URL
        @Published private(set) var done = 0
        @Published private(set) var status = "Gathering your Easels…"
        private let cancelFlag = Flag()
        var total: Int { list.count }

        init(list: [EaselFiles.Summary], url: URL) {
            self.list = list
            self.url = url
        }

        func cancel() { cancelFlag.set() }

        // Arc's verbs for the Easel being exported.
        static let verbs = ["Packing up", "Rolling up", "Framing", "Wrapping"]

        fileprivate func run(_ finished: @escaping (Result) -> Void) {
            // Open editors' last changes first: the export reads the files.
            EaselCenter.shared.saveAll(wait: true)
            let files = EaselCenter.shared.files, list = self.list, url = self.url, flag = cancelFlag
            let shared = Set(list.map(\.id).filter { !SharingCenter.shared.links(of: $0).isEmpty })
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let fm = FileManager.default
                let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
                var entries: [EaselArchive.Entry] = []
                func end(ok: Bool, cancelled: Bool) {
                    if !ok || cancelled { try? fm.removeItem(at: temp) }
                    let r = Result(url: url, entries: entries, ok: ok, cancelled: cancelled)
                    DispatchQueue.main.async { finished(r) }
                }
                let root = (url.lastPathComponent as NSString).deletingPathExtension
                guard let w = try? EaselArchive.Writer(url: temp, root: root.isEmpty ? EaselArchive.name() : root) else { return end(ok: false, cancelled: false) }
                var posted = 0.0
                for (i, s) in list.enumerated() {
                    if flag.isSet { w.abandon(); return end(ok: false, cancelled: true) }
                    // At most one progress update a frame, however fast the Easels go.
                    let now = CACurrentMediaTime()
                    if now - posted > 1.0 / 60 {
                        posted = now
                        let verb = Self.verbs[(i / 4) % Self.verbs.count]
                        DispatchQueue.main.async { self?.done = i; self?.status = "\(verb) “\(s.displayTitle)”" }
                    }
                    let loaded = files.load(s.id)
                    let doc = loaded.document
                    if doc.blocks.isEmpty {
                        // Nothing on it (or nothing that reads): logged, not in the archive.
                        w.skip(title: s.title, outcome: loaded.source == .document ? .empty : .failed)
                        continue
                    }
                    let out = EaselOutgoing.make(doc, easelID: s.id, files: files)
                    do {
                        try w.add(out.easel, pictures: out.pictures, report: out.report, shared: shared.contains(s.id))
                    } catch {
                        w.skip(title: s.title)
                    }
                }
                entries = w.entries
                if flag.isSet { w.abandon(); return end(ok: false, cancelled: true) }
                DispatchQueue.main.async { self?.done = list.count; self?.status = "Finishing up…" }
                do {
                    try w.finish()
                    if fm.fileExists(atPath: url.path) {
                        _ = try fm.replaceItemAt(url, withItemAt: temp)
                    } else {
                        try fm.moveItem(at: temp, to: url)
                    }
                    end(ok: true, cancelled: false)
                } catch {
                    NSLog("Airc: Export All Easels failed: %@", String(describing: error))
                    end(ok: false, cancelled: false)
                }
            }
        }
    }

    /// A flag the main thread sets and the export reads.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// "Saving your Easels…": the bar, the Easel being exported, "<n> of <total>", Cancel.
    final class ProgressSheet {
        let window: NSWindow
        init(job: Job) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Saving your Easels…"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ProgressBody(job: job))
        }
    }

    private struct ProgressBody: View {
        @ObservedObject var job: Job
        @State private var cancelling = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Saving your Easels…").font(.system(size: 15, weight: .semibold)).testAnchor("easelAll.title")
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).testAnchor("easelAll.bar")
                HStack {
                    Text(job.status).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).testAnchor("easelAll.status")
                    Spacer(minLength: 8)
                    Text("\(min(job.done + 1, job.total)) of \(job.total)").monospacedDigit().foregroundStyle(.secondary).testAnchor("easelAll.count")
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        cancelling = true
                        job.cancel()
                    }
                    .keyboardShortcut(.cancelAction).disabled(cancelling).testAnchor("easelAll.cancel")
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }
}

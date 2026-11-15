// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import SwiftUI
import WebKit

/// P19d: "Add to Airc" for a shared Easel link (aircbrowser.com/e/<id>, its page's airc://easel/<id>), as Space and
/// folder links are added (ShareImportSheet). Arc offered a shared Easel as a shared item in your sidebar, kept live with
/// the original; Airc makes a copy that's the person's own: new ids, not linked to the original, and sharing it again
/// makes a new link.
///
/// The Easel and each picture are fetched and checked first (AircKit's EaselImport: the service's schema, web addresses
/// only, pictures by their bytes, size limits); anything that fails refuses the whole link and nothing is added. The
/// sheet then shows the board as the shared page draws it (EaselHTML in a WKWebView with JavaScript off and no
/// navigation) and the Space it goes to. Nothing is added until Add Easel; ⌘Z takes the row back.
final class EaselImportSheet: ObservableObject {
    static var active: [ObjectIdentifier: EaselImportSheet] = [:]
    #if AIRC_TESTING
    /// The last refusal (its alert is the window's sheet), and the last Easel added, for the checks.
    static var lastError: String?
    static var lastAdded: String?
    #endif

    enum Phase: Equatable { case loading(Double), ready, failed(String) }

    let id: String
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    @Published private(set) var phase = Phase.loading(0)
    @Published private(set) var easel: EaselPublic?
    @Published private(set) var message: String?
    @Published var destination: String
    let destinations: [ShareImportSheet.Destination]
    /// The checked pictures by name, with their sizes in pixels.
    private var pictures: [String: (data: Data, width: Double, height: Double)] = [:]
    private var task: Task<Void, Never>?
    private(set) var previewFolder: URL?
    let preview: WKWebView

    init(id: String, controller: WindowController) {
        self.id = id
        self.controller = controller
        parent = controller.window
        let store = controller.store
        let profile = store.profile(ofSpace: controller.currentSpaceID).id
        destinations = store.orderedSpaces.filter { $0.profileID == profile && !$0.isBlankWindow }
            .map { .init(id: $0.id, title: $0.name.isEmpty ? "Space" : $0.name) }
        destination = controller.currentSpaceID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        preview = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), configuration: config)
        preview.navigationDelegate = EaselShareSheet.PreviewNavigation.shared
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Shared Easel"
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: EaselImportView(sheet: self))
    }

    /// Opens Easel link `id` in `c`: the sheet, which fetches and checks it.
    static func open(id: String, in c: WindowController) {
        guard c.window.attachedSheet == nil else { return NSSound.beep() }
        EaselImportSheet(id: id, controller: c).present()
    }

    var title: String { easel?.displayTitle ?? "Shared Easel" }
    var summary: String { easel.map(EaselImport.summary) ?? "Opening…" }
    var destinationName: String { destinations.first { $0.id == destination }?.title ?? "this Space" }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
        load()
    }

    func close() {
        task?.cancel()
        guard let parent else { return }
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
    }

    /// The Easel, then each picture (each checked as it arrives); any failure refuses the link whole.
    private func load() {
        let service = SharingCenter.shared.service, id = self.id
        task = Task { @MainActor [weak self] in
            do {
                let e = try await service.easel(id: id)
                var got: [String: (data: Data, width: Double, height: Double)] = [:]
                for (i, a) in e.assets.enumerated() {
                    try Task.checkCancellation()
                    got[a.name] = try await service.easelPicture(id: id, a)
                    self?.phase = .loading(Double(i + 1) / Double(max(1, e.assets.count)))
                }
                try Task.checkCancellation()
                self?.loaded(e, got)
            } catch is CancellationError {
                return
            } catch {
                self?.failed(error)
            }
        }
    }

    private func loaded(_ e: EaselPublic, _ got: [String: (data: Data, width: Double, height: Double)]) {
        guard Self.active.values.contains(where: { $0 === self }) else { return }
        easel = e
        pictures = got
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Easel Preview/\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            for (n, p) in got { try p.data.write(to: assets.appendingPathComponent(n)) }
            let page = dir.appendingPathComponent("index.html")
            try Data(EaselHTML.page(e, note: EaselHTML.sharedNote, asset: { "assets/\($0)" }).utf8).write(to: page)
            previewFolder = dir
            preview.loadFileURL(page, allowingReadAccessTo: dir)
        } catch {
            // The preview is only a picture of it; adding still works.
            message = "Airc couldn’t show a preview."
        }
        phase = .ready
    }

    private func failed(_ error: Error) {
        let text = error.localizedDescription
        #if AIRC_TESTING
        Self.lastError = text
        #endif
        LinkLog.write("easel link: refused (\(text))")
        phase = .failed(text)
    }

    /// Add Easel: a new Easel of the person's own with the shared one's items, pinned at the end of the chosen Space's
    /// pinned tabs and shown. The document and pictures are written first, so the row never points at nothing.
    func add() {
        guard phase == .ready, let e = easel, let c = controller else { return NSSound.beep() }
        let files = EaselCenter.shared.files
        let doc = EaselImport.document(e, pixels: pictures.mapValues { ($0.width, $0.height) })
        do {
            for (name, p) in pictures {
                guard try files.addAsset(p.data, ext: String(name.split(separator: ".")[1]), to: doc.id) == name else { throw EaselImport.Failure.picture }
            }
            try files.save(doc)
            // One ⌘Z step, as Add Shared Space is: it takes the row back (the Easel stays in Library › Easels).
            let t = try c.store.createEasel(doc.id, inSpace: destination, title: doc.title, undoLabel: "Add Easel")
            close()
            let here = destination == c.currentSpaceID
            if !here { c.switchToSpace(destination, animated: true) }
            c.show(t.id)
            c.showToast("Added “\(doc.displayTitle)” to \(here ? "this Space" : "“\(destinationName)”")")
            #if AIRC_TESTING
            Self.lastAdded = doc.id
            #endif
        } catch {
            try? FileManager.default.removeItem(at: files.folder(doc.id))
            message = "Airc couldn’t add it: \(error.localizedDescription)"
        }
    }
}

private struct EaselImportPreview: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct EaselImportView: View {
    @ObservedObject var sheet: EaselImportSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "scribble.variable").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.title).font(.system(size: 20, weight: .semibold)).lineLimit(1).testAnchor("easelImport.title")
                    Text("A shared Easel · " + sheet.summary).foregroundStyle(.secondary).testAnchor("easelImport.summary")
                }
            }
            EaselImportPreview(web: sheet.preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: NSColor(easelHex: "#EBE8E4"))))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .overlay {
                    switch sheet.phase {
                    case .loading(let p):
                        if p > 0 { ProgressView(value: p).frame(width: 160) } else { ProgressView().controlSize(.small) }
                    case .failed(let why):
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(.secondary)
                            Text("Couldn’t open this link").font(.headline)
                            Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true).testAnchor("easelImport.error")
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                    case .ready:
                        EmptyView()
                    }
                }
                .testAnchor("easelImport.preview")
            if sheet.destinations.count > 1 {
                Picker("Add to Space", selection: $sheet.destination) {
                    ForEach(sheet.destinations) { d in Text(d.title).tag(d.id) }
                }
                .disabled(sheet.phase != .ready)
                .testAnchor("easelImport.destination")
            }
            Text("It’s added to the end of “\(sheet.destinationName)”’s pinned tabs as an Easel of your own: what you change stays on this Mac, and the original doesn’t change it. Sharing it makes a new link. Nothing opens until you click a link.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let m = sheet.message { Text(m).foregroundStyle(.red).testAnchor("easelImport.message") }
            HStack {
                Spacer()
                Button("Cancel", action: sheet.close).keyboardShortcut(.cancelAction).testAnchor("easelImport.cancel")
                Button("Add Easel", action: sheet.add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(sheet.phase != .ready).testAnchor("easelImport.add")
            }
        }.padding(24).frame(width: 640, height: 620).background(.background)
    }
}

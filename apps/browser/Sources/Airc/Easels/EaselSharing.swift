// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// P19c (parity N08): an Easel out of Airc, as Arc let you: Export (a PNG of the whole Easel or the selection at 1× or
// 2×, or a web page in a ZIP that opens offline), Copy Image, Share… (the system's picker with the picture), and Share
// Link… (a read-only snapshot on aircbrowser.com/e/<id>, the sharing service's Easel links). What leaves is AircKit's
// EaselPublic: the blocks, their pictures and cleaned web addresses, never a profile, cookie, token or a live
// Capture's page state; a live Capture goes as its last picture. Private windows have no Easels (their controller has
// no Easel to show), and a private window's Capture never reaches one (P19b), so nothing private can be in it.

/// An Easel (or some of its blocks) drawn into one picture by the canvas's own block layers.
enum EaselPicture {
    static let margin = 24.0
    /// The longest side of a picture, in pixels; a larger Easel comes out at a lower scale.
    static let maxPixels = 16_384.0

    /// The picture of blocks `ids` (every block when nil) at `scale` pixels per point, on the Easel's background in
    /// `look`. Live Captures show their last picture without the Live chip. nil for nothing to draw.
    /// `transparent`: no background, and the picture cut to the pixels that show something (Export as Image…).
    static func render(_ doc: EaselDocument, easelID: String, only ids: Set<String>? = nil, scale: Double, look: EaselLook,
                       transparent: Bool = false) -> (image: CGImage, scale: Double)? {
        let blocks = doc.stacked.filter { ids?.contains($0.id) ?? true }
        guard let content = blocks.map(\.bounds).reduce(nil as EaselRect?, { $0?.union($1) ?? $1 }) else { return nil }
        let box = EaselRect(x: content.x - margin, y: content.y - margin, width: content.width + 2 * margin, height: content.height + 2 * margin)
        let s = min(scale, maxPixels / max(box.width, box.height, 1))
        let w = Int((box.width * s).rounded(.up)), h = Int((box.height * s).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if !transparent {
            ctx.setFillColor(look.background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        for b in blocks {
            let layer = EaselBlockLayer(block: b, look: look, easelID: easelID)
            layer.exporting = true
            ctx.saveGState()
            // The context is y-up; the plane is y-down. The block's centre, then its turn (clockwise on screen).
            ctx.translateBy(x: (b.frame.midX - box.x) * s, y: Double(h) - (b.frame.midY - box.y) * s)
            ctx.scaleBy(x: s, y: s)
            ctx.rotate(by: -b.rotation)
            ctx.translateBy(x: -layer.bounds.width / 2, y: -layer.bounds.height / 2)
            layer.draw(in: ctx)
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { return nil }
        guard transparent else { return (image, s) }
        // The bitmap's first row in memory is the picture's top row, as CGImage cropping counts.
        guard let data = ctx.data,
              let box = EaselTrim.opaqueBounds(UnsafeRawBufferPointer(start: data, count: ctx.bytesPerRow * h), width: w, height: h,
                                               bytesPerRow: ctx.bytesPerRow),
              let cut = image.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) else { return nil }
        return (cut, s)
    }

    /// PNG bytes that say their scale (144 dpi at 2×), so a 2× picture places at its size in points.
    static func png(_ image: CGImage, scale: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }
}

/// What an export or a link sends: the public form, with its pictures as they go out.
struct EaselOutgoing: @unchecked Sendable {
    var easel: EaselPublic
    var report: EaselPublic.Report
    var pictures: [String: Data]

    /// A picture's bytes as they leave: PNG, JPEG, GIF and WebP as they are when they fit (4 MB); anything else (HEIC),
    /// or larger, re-encoded smaller (JPEG, or PNG when it has transparency).
    static func pictureData(_ files: EaselFiles, easelID: String, asset: String) -> Data? {
        guard let url = files.assetURL(easelID, asset), let data = try? Data(contentsOf: url) else { return nil }
        if EaselPublic.pictureType(data) != nil, data.count <= EaselPublic.maxAssetBytes { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for side in [4096, 3072, 2048, 1536, 1024] {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= EaselPublic.maxAssetBytes { return out as Data }
        }
        return nil
    }

    /// The public form of `doc` (blocks `ids` only, when given), its pictures read and converted off the main thread.
    static func prepare(_ doc: EaselDocument, easelID: String, only ids: Set<String>? = nil, _ done: @escaping (EaselOutgoing) -> Void) {
        let files = EaselCenter.shared.files
        DispatchQueue.global(qos: .userInitiated).async {
            let out = make(doc, easelID: easelID, only: ids, files: files)
            DispatchQueue.main.async { done(out) }
        }
    }

    /// The same, on the caller's thread (never the main one: it reads and converts every picture). Export All Easels
    /// makes each Easel's this way, one after another.
    static func make(_ doc: EaselDocument, easelID: String, only ids: Set<String>? = nil, files: EaselFiles) -> EaselOutgoing {
        var (easel, report) = EaselPublic.make(doc, only: ids)
        var map: [String: EaselPublic.Asset] = [:], pictures: [String: Data] = [:]
        for local in easel.pictureNames {
            guard let d = pictureData(files, easelID: easelID, asset: local), let name = EaselPublic.pictureName(d) else { continue }
            map[local] = EaselPublic.Asset(name: name, size: d.count)
            pictures[name] = d
        }
        easel = easel.settingPictures(map, report: &report)
        return EaselOutgoing(easel: easel, report: report, pictures: pictures)
    }

    /// What the preview says isn't in it, or was changed.
    var notes: String {
        var parts: [String] = []
        func n(_ count: Int, _ one: String, _ many: String) { if count > 0 { parts.append(count == 1 ? one : "\(count) \(many)") } }
        n(report.leftOut, "1 item made by a newer Airc is left out", "items made by a newer Airc are left out")
        n(report.linksDropped, "1 link that isn’t a web address is left out", "links that aren’t web addresses are left out")
        n(report.picturesMissing, "1 picture that couldn’t be read is left out", "pictures that couldn’t be read are left out")
        n(report.addressesCleaned, "1 address lost its sign-in or session part", "addresses lost their sign-in or session parts")
        n(report.liveCaptures, "1 Live Capture goes as its last picture", "Live Captures go as their last pictures")
        return parts.map { $0 + "." }.joined(separator: " ")
    }
}

// MARK: - Export, Copy Image, Share…

extension EaselEditor {
    /// What `write` makes (the checks call it directly, the selection or 1× included); the app's panels make `ExportKind`s.
    enum ExportFormat: Int, CaseIterable {
        case png1, png2, html
    }

    /// Arc's two Export items (its Easel menu: "Export as Image", "Export as Web Page…"): the whole Easel as a PNG at
    /// 2× on a transparent background cut to what shows, or the web page ZIP. Each asks where in a save panel.
    enum ExportKind: Int, CaseIterable {
        case image, webPage
        /// The save panel's Format menu.
        var formatTitle: String { self == .image ? "Image (PNG)" : "Web Page (ZIP)" }
        var type: UTType { self == .image ? .png : .zip }
        var pathExtension: String { self == .image ? "png" : "zip" }
    }

    /// The look an export draws in: the canvas's when it's on screen, else the Easel's palette in the window's mode.
    var exportLook: EaselLook {
        view.window != nil ? look : EaselLook(palette: document.palette, dark: controller?.currentPalette.isDark ?? false)
    }

    /// Export as Image… / Export as Web Page…: a save panel for the one format, the whole Easel. Without a kind (File ›
    /// Export Easel…, the Command Bar, the canvas's Export…) the same panel with a Format menu of the two.
    func export(_ kind: ExportKind? = nil) {
        guard let window = view.window ?? controller?.window else { return NSSound.beep() }
        EaselExporting.run(kind, editor: self, window: window, controller: controller)
    }

    /// Writes the export (the checks call this without the panel).
    func write(_ format: ExportFormat, ids: Set<String>?, to url: URL, done: @escaping (Bool) -> Void) {
        saveNow(wait: true)
        switch format {
        case .png1, .png2:
            let scale = format == .png2 ? 2.0 : 1.0
            guard let (image, s) = EaselPicture.render(document, easelID: easelID, only: ids, scale: scale, look: exportLook),
                  let data = EaselPicture.png(image, scale: s), (try? data.write(to: url, options: .atomic)) != nil else { return done(false) }
            done(true)
        case .html:
            EaselOutgoing.prepare(document, easelID: easelID, only: ids) { out in
                guard !out.easel.blocks.isEmpty, let zip = try? EaselExport.htmlArchive(out.easel, pictures: out.pictures),
                      (try? zip.write(to: url, options: .atomic)) != nil else { return done(false) }
                done(true)
            }
        }
    }

    /// Copy Image: the selection (or the whole Easel) as a 2× picture on the clipboard, PNG and TIFF.
    func copyImage() {
        guard let (image, s) = EaselPicture.render(document, easelID: easelID, only: selection.isEmpty ? nil : selection, scale: 2, look: look),
              let png = EaselPicture.png(image, scale: s) else { return NSSound.beep() }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: Double(image.width) / s, height: Double(image.height) / s)
        let pb = NSPasteboard.general
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        controller?.showToast(selection.isEmpty ? "Copied the Easel as a picture" : "Copied as a picture")
    }

    /// Share…: the system's picker (Messages, Mail, AirDrop, Notes…) with the Easel's picture as a file named after it.
    func sharePicture(from anchor: NSView?) {
        guard let (image, s) = EaselPicture.render(document, easelID: easelID, only: selection.isEmpty ? nil : selection, scale: 2, look: look),
              let png = EaselPicture.png(image, scale: s) else { return NSSound.beep() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Easels/\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent(EaselExport.fileName(document.title) + ".png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch { return NSSound.beep() }
        let picker = NSSharingServicePicker(items: [file])
        let target = anchor ?? view.canvas
        picker.show(relativeTo: target.bounds, of: target, preferredEdge: .minY)
    }

    /// Share Link…: the preview of exactly what will be published, then Create Link.
    func shareLink() {
        guard let c = controller else { return NSSound.beep() }
        saveNow(wait: true)
        EaselShareSheet(editor: self, controller: c).present()
    }
}

/// Export as Image… and Export as Web Page… for an Easel on screen or one in Library › Easels (its editor needn't be
/// shown: the document, its pictures and its look are enough).
enum EaselExporting {
    /// The panel open now (the checks drive it with real keys).
    private(set) static weak var panel: NSSavePanel?
    /// The panel's Format menu, when it has one (File › Export Easel…).
    private(set) static weak var formats: EaselFormatChooser?
    /// The last export written, its kind, and whether it worked (the checks wait for it).
    private(set) static var last: (url: URL, kind: EaselEditor.ExportKind, ok: Bool)?
    /// The kind File › Export Easel… offers first: the last one exported from it.
    static var lastChosen = EaselEditor.ExportKind.image

    /// One save panel for every Easel export. With `kind` it's that one (the Easel's and the Library's Export as Image…
    /// and Export as Web Page…); without, it starts at the last kind and has a Format menu of both, and a name typed
    /// with the other's extension (".zip", ".png") picks that one.
    static func run(_ kind: EaselEditor.ExportKind?, editor: EaselEditor, window: NSWindow, controller: WindowController?) {
        guard !editor.document.isEmpty else {
            controller?.showToast("There’s nothing on this Easel to export")
            return
        }
        guard window.attachedSheet == nil else { return NSSound.beep() }
        let p = NSSavePanel()
        let base = EaselExport.fileName(editor.document.title)
        p.prompt = "Export"
        p.isExtensionHidden = false
        p.canCreateDirectories = true
        let chooser = kind == nil ? EaselFormatChooser(kind: lastChosen, panel: p, base: base) : nil
        if let chooser {
            p.accessoryView = chooser.view
            // Both, so a typed extension isn't questioned; `chosenKind` reads it.
            p.allowedContentTypes = [.png, .zip]
        }
        configure(p, kind ?? lastChosen, base: base, chooser: chooser != nil)
        panel = p
        formats = chooser
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let url = p.url else { return }
            let chosen = kind ?? chosenKind(url, chooser?.kind ?? lastChosen)
            if kind == nil { lastChosen = chosen }
            write(chosen, editor: editor, to: url) { ok in
                controller?.showToast(ok ? "Exported “\(url.lastPathComponent)”" : "Airc couldn’t export the Easel")
            }
        }
    }

    /// The panel's title, message, types and name for `kind`.
    static func configure(_ p: NSSavePanel, _ kind: EaselEditor.ExportKind, base: String, chooser: Bool) {
        switch kind {
        case .image:
            p.title = chooser ? "Export Easel" : "Export as Image"
            p.message = "Save this Easel as a picture."
        case .webPage:
            // Arc's save panel message for one Easel.
            p.title = chooser ? "Export Easel" : "Export as Web Page"
            p.message = "Save this Easel as a web page you can open anywhere."
        }
        if !chooser { p.allowedContentTypes = [kind.type] }
        p.nameFieldStringValue = base + "." + kind.pathExtension
    }

    /// The kind a name says (its extension), else the Format menu's.
    static func chosenKind(_ url: URL, _ menu: EaselEditor.ExportKind) -> EaselEditor.ExportKind {
        EaselEditor.ExportKind.allCases.first { $0.pathExtension == url.pathExtension.lowercased() } ?? menu
    }

    /// Writes `kind` of the whole Easel to `url`.
    static func write(_ kind: EaselEditor.ExportKind, editor: EaselEditor, to url: URL, done: @escaping (Bool) -> Void) {
        let finish = { (ok: Bool) in
            last = (url, kind, ok)
            done(ok)
        }
        switch kind {
        case .image:
            editor.saveNow(wait: true)
            guard let (image, s) = EaselPicture.render(editor.document, easelID: editor.easelID, scale: 2, look: editor.exportLook, transparent: true),
                  let data = EaselPicture.png(image, scale: s), (try? data.write(to: url, options: .atomic)) != nil else { return finish(false) }
            finish(true)
        case .webPage:
            editor.write(.html, ids: nil, to: url, done: finish)
        }
    }
}

/// File › Export Easel…'s Format menu: Image (PNG) or Web Page (ZIP). Changing it changes the name's extension and the
/// panel's message.
final class EaselFormatChooser: NSObject {
    let view: NSView
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private let base: String
    private(set) var kind: EaselEditor.ExportKind

    init(kind: EaselEditor.ExportKind, panel: NSSavePanel, base: String) {
        self.kind = kind
        self.panel = panel
        self.base = base
        popup.addItems(withTitles: EaselEditor.ExportKind.allCases.map(\.formatTitle))
        popup.selectItem(at: kind.rawValue)
        popup.setAccessibilityIdentifier("easelExport.format")
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = row
        super.init()
        popup.target = self
        popup.action = #selector(changed)
        objc_setAssociatedObject(panel, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var key: UInt8 = 0

    @objc private func changed() { choose(EaselEditor.ExportKind(rawValue: popup.indexOfSelectedItem) ?? .image) }

    func choose(_ k: EaselEditor.ExportKind) {
        kind = k
        popup.selectItem(at: k.rawValue)
        guard let panel else { return }
        // Keeps a name the person typed; only its extension follows the format.
        let typed = (panel.nameFieldStringValue as NSString).deletingPathExtension
        EaselExporting.configure(panel, k, base: typed.isEmpty ? base : typed, chooser: true)
    }
}

// MARK: - Share Link…

/// Arc's Easel sharing: a read-only snapshot at aircbrowser.com/e/<id>. The sheet shows the page exactly as it will be
/// published (EaselHTML, the same board the service renders) and what's left out, and sends nothing before Create Link.
/// Then Copy Link, Share…, Take Back; earlier links of the same Easel are listed with Take Back. Re-sharing makes a new
/// snapshot (and a new link); editing together isn't a thing links do (docs/user/easels.md).
final class EaselShareSheet: ObservableObject {
    static var active: [ObjectIdentifier: EaselShareSheet] = [:]
    enum Phase: Equatable {
        case preparing
        case preview
        case publishing(Double)
        case published(SharedLinkRecord)
    }
    let easelID: String
    let name: String
    let sheet: NSWindow
    weak var parent: NSWindow?
    weak var controller: WindowController?
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var outgoing: EaselOutgoing?
    @Published private(set) var problem: String?
    @Published private(set) var message: String?
    @Published private(set) var earlier: [SharedLinkRecord]
    @Published private(set) var revoking: Set<String> = []
    /// The page as it will be published, in a folder of its own (deleted when the sheet closes).
    private(set) var previewFolder: URL?
    let preview: WKWebView

    init(editor: EaselEditor, controller: WindowController) {
        easelID = editor.easelID
        name = editor.document.displayTitle
        self.controller = controller
        parent = controller.window
        earlier = SharingCenter.shared.links(of: editor.easelID)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        preview = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), configuration: config)
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Share Easel"
        sheet.isReleasedWhenClosed = false
        preview.navigationDelegate = PreviewNavigation.shared
        sheet.contentView = NSHostingView(rootView: EaselShareView(share: self))
        EaselOutgoing.prepare(editor.document, easelID: editor.easelID) { [weak self] out in self?.prepared(out) }
    }

    var published: SharedLinkRecord? { if case .published(let r) = phase { r } else { nil } }

    private func prepared(_ out: EaselOutgoing) {
        // Closed before it was ready: nothing to show, and no preview folder to leave behind.
        guard Self.active.values.contains(where: { $0 === self }) else { return }
        outgoing = out
        do {
            try out.easel.check()
        } catch {
            problem = error.localizedDescription
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Easel Preview/\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            for (n, d) in out.pictures { try d.write(to: assets.appendingPathComponent(n)) }
            let page = dir.appendingPathComponent("index.html")
            try Data(EaselHTML.page(out.easel, note: EaselHTML.sharedNote, asset: { "assets/\($0)" }).utf8).write(to: page)
            previewFolder = dir
            preview.loadFileURL(page, allowingReadAccessTo: dir)
        } catch {
            problem = problem ?? "Airc couldn’t prepare the preview."
        }
        phase = .preview
    }

    func present() {
        guard let parent, parent.attachedSheet == nil else { NSSound.beep(); return }
        Self.active[ObjectIdentifier(parent)] = self
        parent.beginSheet(sheet)
    }

    func close() {
        guard let parent else { return }
        parent.endSheet(sheet)
        sheet.orderOut(nil)
        Self.active[ObjectIdentifier(parent)] = nil
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
    }

    /// Create Link: the Easel and its pictures go to aircbrowser.com; the link comes back with its key.
    func create() {
        guard phase == .preview, problem == nil, let out = outgoing else { return NSSound.beep() }
        phase = .publishing(0)
        message = nil
        Task { @MainActor in
            do {
                let r = try await SharingCenter.shared.publishEasel(out.easel, pictures: out.pictures, easelID: easelID) { p in
                    DispatchQueue.main.async { [weak self] in if case .publishing = self?.phase { self?.phase = .publishing(p) } }
                }
                phase = .published(r)
                earlier = SharingCenter.shared.links(of: easelID)
            } catch {
                phase = .preview
                message = error.localizedDescription
            }
        }
    }

    func copyLink() {
        guard let r = published else { return NSSound.beep() }
        close()
        controller?.writeLinks(r.url.absoluteString, toast: "Copied Link")
    }

    func copy(_ r: SharedLinkRecord) { controller?.writeLinks(r.url.absoluteString, toast: "Copied Link") }

    func shareWithPicker() {
        guard let r = published, let view = sheet.contentView, let share = SelectionShare([r.url.absoluteString]) else { return NSSound.beep() }
        share.show(relativeTo: NSRect(x: view.bounds.maxX - 200, y: 20, width: 80, height: 24), of: view, edge: .minY)
    }

    /// Take Back: asks first; then the page and its pictures are gone (404) for everyone.
    func takeBack(_ r: SharedLinkRecord, confirmed: Bool = false) {
        guard confirmed else {
            let alert = NSAlert()
            alert.messageText = "Take back this link?"
            alert.informativeText = "Anyone who opens it will see that it was taken back."
            alert.addButton(withTitle: "Take Back")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sheet) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.takeBack(r, confirmed: true) }
            }
            return
        }
        revoking.insert(r.id)
        Task { @MainActor in
            defer { revoking.remove(r.id) }
            do {
                try await SharingCenter.shared.revoke(r)
                earlier = SharingCenter.shared.links(of: easelID)
                if published?.id == r.id { phase = .preview }
                message = "Link taken back."
            } catch SharingCenter.RevokeFailure.noToken {
                SharingCenter.shared.forget(r)
                earlier = SharingCenter.shared.links(of: easelID)
                message = SharingCenter.RevokeFailure.noToken.localizedDescription
            } catch {
                message = error.localizedDescription
            }
        }
    }

    var summary: String {
        guard let e = outgoing?.easel else { return "Preparing…" }
        let items = e.blocks.count == 1 ? "1 item" : "\(e.blocks.count) items"
        let pictures = e.assets.isEmpty ? "" : e.assets.count == 1 ? " · 1 picture" : " · \(e.assets.count) pictures"
        return items + pictures
    }

    var leftOutText: String {
        let never = "Cookies, sign-ins, the pages behind Live Captures and your undo history are never in a link."
        let notes = outgoing?.notes ?? ""
        return notes.isEmpty ? never : notes + " " + never
    }

    /// The preview never goes anywhere: clicks on its links do nothing.
    final class PreviewNavigation: NSObject, WKNavigationDelegate {
        static let shared = PreviewNavigation()
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true && action.navigationType == .other ? .allow : .cancel)
        }
    }
}

private struct EaselPreviewView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct EaselShareView: View {
    @ObservedObject var share: EaselShareSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "scribble.variable").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Easel “\(share.name)”").font(.system(size: 20, weight: .semibold)).lineLimit(1).testAnchor("easelShare.title")
                    Text(share.summary).foregroundStyle(.secondary).testAnchor("easelShare.summary")
                }
            }
            EaselPreviewView(web: share.preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: NSColor(easelHex: "#EBE8E4"))))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .overlay { if share.phase == .preparing { ProgressView().controlSize(.small) } }
                .testAnchor("easelShare.preview")
            if let r = share.published {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(r.url.absoluteString).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .truncationMode(.middle).testAnchor("easelShare.link")
                }
                Text("Anyone with this link can see this Easel, read-only, in any browser. Later changes don’t reach it. Take it back here whenever you like.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Create Link puts exactly what’s shown above on aircbrowser.com, where anyone with the link can see it. It’s a snapshot: later changes don’t reach it. You can take it back.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(share.leftOutText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .testAnchor("easelShare.leftOut")
            }
            let others = share.earlier.filter { $0.id != share.published?.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(others.count == 1 ? "A link you made earlier" : "Links you made earlier").font(.callout.weight(.semibold))
                    ForEach(others) { r in
                        HStack(spacing: 8) {
                            Text((r.url.host ?? "") + r.url.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Copy") { share.copy(r) }.controlSize(.small)
                            Button("Take Back") { share.takeBack(r) }.controlSize(.small).disabled(share.revoking.contains(r.id))
                                .testAnchor("easelShare.takeBack.\(r.id)")
                        }
                    }
                }
            }
            if let p = share.problem { Text(p).foregroundStyle(.red).testAnchor("easelShare.error") }
            if let m = share.message { Text(m).font(.callout).foregroundStyle(.secondary).testAnchor("easelShare.message") }
            HStack {
                if let r = share.published {
                    Button("Take Back") { share.takeBack(r) }.disabled(share.revoking.contains(r.id)).testAnchor("easelShare.takeBack")
                }
                Spacer()
                switch share.phase {
                case .published:
                    Button("Done", action: share.close).keyboardShortcut(.cancelAction).testAnchor("easelShare.done")
                    Button("Share…", action: share.shareWithPicker).testAnchor("easelShare.picker")
                    Button("Copy Link", action: share.copyLink).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .testAnchor("easelShare.copy")
                case .preparing, .preview, .publishing:
                    Button("Cancel", action: share.close).keyboardShortcut(.cancelAction).testAnchor("easelShare.cancel")
                    if case .publishing(let p) = share.phase { ProgressView(value: p).frame(width: 80) }
                    Button("Create Link", action: share.create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(share.problem != nil || share.phase != .preview).testAnchor("easelShare.create")
                }
            }
        }.padding(24).frame(width: 640, height: 640).background(.background)
    }
}

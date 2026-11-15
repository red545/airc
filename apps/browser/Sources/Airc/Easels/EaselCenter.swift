// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import UniformTypeIdentifiers

// Easels in the browser window (docs/user/easels.md), as notes are (Notes/NoteCenter.swift): an Easel's tab has no
// engine page; WindowController.show puts its editor in the page card through the notes' seam (`noteEditor(forTab:)`
// returns a CardDocument). One editor per Easel for the whole app, so an Easel shown in another window moves there with
// its undo history. What's on an Easel is in its own folder in the data folder (AircKit's EaselFiles), never the store.

final class EaselCenter {
    static let shared = EaselCenter()
    private var editors: [String: EaselEditor] = [:]
    private var quitObserver: NSObjectProtocol?

    /// The data folder's Easels/ (a `--data-dir` run has its own).
    var files: EaselFiles { EaselFiles(root: AppPaths.dataDirectory.appendingPathComponent("Easels", isDirectory: true)) }

    private init() {
        // P19b: a duplicated Easel row copies its Easel (AircKit's SpacesStore.copiedAddress).
        EaselFiles.shared = files
        // P19c: an undone row copy's Easel was deleted: its editor goes without saving (a save would bring it back).
        EaselFiles.didDelete = { ids in
            for id in ids {
                EaselLiveCenter.shared.cancel(easelID: id)
                EaselCenter.shared.editors[id] = nil
            }
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            EaselCenter.shared.saveAll(wait: true)
        }
    }

    func editor(for easelID: String, store: SpacesStore) -> EaselEditor {
        if let e = editors[easelID] { return e }
        let e = EaselEditor(easelID: easelID, store: store)
        editors[easelID] = e
        return e
    }

    func existingEditor(_ easelID: String) -> EaselEditor? { editors[easelID] }

    /// At launch (before any row can be duplicated): the app's Easels folder for the store's row copies.
    static func register() { _ = shared }

    var openEditors: [EaselEditor] { Array(editors.values) }

    /// Editors of Easels no tab has open and no card shows: saved, then let go (their undo history is on disk).
    func dropClosed(store: SpacesStore) {
        let open = Set(store.state.tabs.values.compactMap { EaselURL.easelID($0.url) })
        for (id, e) in editors where !open.contains(id) && e.view.superview == nil {
            EaselLiveCenter.shared.cancel(easelID: id)
            e.saveNow(wait: false)
            editors[id] = nil
        }
    }

    /// Quit (and the relaunch check): every unsaved change on disk.
    func saveAll(wait: Bool) {
        for e in editors.values { e.saveNow(wait: wait) }
    }

    /// Library › Easels: every Easel on disk, read off the main thread.
    func summaries(_ done: @escaping ([EaselFiles.Summary]) -> Void) {
        saveAll(wait: true)
        let files = self.files
        DispatchQueue.global(qos: .userInitiated).async {
            let list = files.list()
            DispatchQueue.main.async { done(list) }
        }
    }

    // MARK: Pictures in

    /// Keeps picture bytes in Easel `id`'s assets (PNG, JPEG, GIF, HEIC, WebP as they are; TIFF and anything else
    /// NSImage reads as PNG) and returns the picture, sized in pixels.
    func storePicture(_ data: Data, ext: String, in id: String, source: String? = nil) -> EaselImage? {
        var bytes = data
        var ext = ext.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        if !["png", "jpg", "gif", "heic", "webp"].contains(ext) {
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
            ext = "png"
        }
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        guard w >= 1, h >= 1 else { return nil }
        do {
            let name = try files.addAsset(bytes, ext: ext, to: id)
            return EaselImage(asset: name, pixelWidth: w, pixelHeight: h, source: source)
        } catch {
            NSLog("Airc: couldn't keep an Easel's picture: %@", "\(error)")
            return nil
        }
    }

    func storePicture(cgImage: CGImage, in id: String) -> EaselImage? {
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        return storePicture(png, ext: "png", in: id)
    }

    /// The pictures on a pasteboard or drag (image files, a copied image), in order.
    func readPictures(_ pb: NSPasteboard, into id: String) -> [EaselImage] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.compactMap { u -> EaselImage? in
                guard let type = UTType(filenameExtension: u.pathExtension), type.conforms(to: .image),
                      let data = try? Data(contentsOf: u) else { return nil }
                return storePicture(data, ext: u.pathExtension, in: id)
            }
            if !images.isEmpty { return images }
        }
        let source = pb.string(forType: NSPasteboard.PasteboardType("public.url")) ?? pb.string(forType: .URL)
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
                            (NSPasteboard.PasteboardType("public.heic"), "heic"), (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"),
                            (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"), (NSPasteboard.PasteboardType.tiff, "tiff")] {
            if let data = pb.data(forType: type), let image = storePicture(data, ext: ext, in: id, source: source) { return [image] }
        }
        return []
    }
}

extension WindowController {
    /// The Easel on screen in this window's card, if one is.
    var shownEasel: EaselEditor? {
        guard multiWindow.elsewhereTabID == nil, let id = EaselURL.easelID(store.tab(shownTabID)?.url),
              let e = EaselCenter.shared.existingEditor(id), e.view.superview === card else { return nil }
        return e
    }

    /// Arc's New Easel (⌃⇧E, File › New Easel, the Command Bar, the sidebar's "+"): pinned in the current Space, shown,
    /// its title ready to type. Private windows and Little Arc have no Easels (their keys don't reach here).
    @discardableResult
    func newEasel(title: String = "") -> String? {
        closeCommandBar()
        let id = newID()
        // The document first: its row never points at nothing.
        let doc = EaselDocument(id: id, title: title)
        do { try EaselCenter.shared.files.save(doc) } catch { NSSound.beep(); return nil }
        guard let t = try? store.createEasel(id, inSpace: currentSpaceID, title: title) else { NSSound.beep(); return nil }
        show(t.id)
        DispatchQueue.main.async { [weak self] in
            if title.isEmpty { self?.shownEasel?.focusTitle() } else { self?.shownEasel?.focus() }
        }
        return id
    }

    /// An Easel's title changed: its rows and the window title follow.
    func easelTitleChanged() {
        refreshChrome()
        pageView(for: currentSpaceID)?.reload(animated: false)
    }

    /// Opens a link from an Easel (a link card's double-click) in a new tab beside it.
    func openFromEasel(_ url: URL) {
        guard let t = try? store.openTab(url: url.absoluteString, inSpace: currentSpaceID, title: url.host ?? url.absoluteString) else { return }
        reloadAll(animated: false)
        show(t.id)
    }
}

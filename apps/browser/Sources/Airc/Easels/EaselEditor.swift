// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// One Easel's editor: its document, its own undo history (EaselHistory, saved beside the document so the last
/// session's steps survive a relaunch), its selection, and its view. Every change is in memory at once and on disk
/// 0.4 s later (atomically, the version before kept as a .bak), and at once when the Easel closes or Airc quits.
final class EaselEditor: NSObject, CardDocument {
    let easelID: String
    private(set) var view: EaselEditorView!
    private weak var store: SpacesStore?
    weak var controller: WindowController?
    private(set) var document: EaselDocument
    private(set) var history: EaselHistory
    /// What reading a damaged file left out (EaselFiles' recovery), shown in a bar over the canvas until dismissed.
    private(set) var recoveryMessage: String?
    var selection: Set<String> = [] {
        didSet { if selection != oldValue { view?.canvas.selectionChanged(); view?.toolbar.refresh() } }
    }
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private static let saveQueue = DispatchQueue(label: "org.airc.easels.save", qos: .utility)
    /// Saves done (the relaunch check waits for them).
    private(set) var saves = 0

    /// What new blocks look like (Arc kept the last colour and family you picked).
    /// nil until a colour is picked: each shape kind its own (Arc: rectangles light green, circles red).
    static var lastFill: EaselColor?
    static var lastLineColor: EaselColor = .lightBlue
    static var lastFont: EaselFont = .clean
    static var lastTextSize: Double = EaselText.defaultSize

    init(easelID: String, store: SpacesStore) {
        self.easelID = easelID
        self.store = store
        let files = EaselCenter.shared.files
        let r = files.load(easelID)
        var doc = r.document
        if case .missing = r.source {
            // A row with no document (copied from another Mac's backup, its folder deleted): an empty Easel named as the row.
            let row = store.tabs(showingEasel: easelID).first?.title ?? store.archiveEntries(ofEasel: easelID).first?.title
            if let row, row != EaselURL.untitled { doc.title = row }
        }
        document = doc
        history = files.loadHistory(for: doc) ?? EaselHistory()
        recoveryMessage = r.message
        if let m = r.message { NSLog("Airc: Easel %@: %@", easelID, m) }
        super.init()
        view = EaselEditorView(editor: self)
        view.titleField.stringValue = doc.title
        view.showRecovery(recoveryMessage)
        view.canvas.sync()
        view.canvas.restoreViewport(doc.viewport)
    }

    var cardView: NSView { view }
    var title: String { document.title }

    func focus() { view.window?.makeFirstResponder(view.canvas) }
    func focusTitle() { view.window?.makeFirstResponder(view.titleField) }

    func prepare(for c: WindowController) {
        controller = c
        // A pinned row renamed in the sidebar names the Easel.
        if let name = store?.easelRowName(easelID), name != document.title { rename(name) }
        view.apply(EaselLook(palette: document.palette, dark: c.currentPalette.isDark), palette: c.currentPalette, cornerRadius: c.card.cornerRadius)
        // P19b: Live Captures that are due refresh as the Easel opens.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            EaselLiveCenter.shared.shown(self)
        }
    }

    var look: EaselLook { view.look }

    // MARK: Changes

    /// One undoable change, named for Edit › Undo; `select` replaces the selection after it.
    func change(_ name: String, select: Set<String>? = nil, _ body: (inout EaselDocument) -> Void) {
        let before = document
        var d = document
        body(&d)
        guard d != before else {
            if let select { selection = select }
            return
        }
        d.updatedAt = Date()
        history.record(name, from: before, to: d)
        commit(d, select: select)
    }

    /// During a drag: shown at once, saved and undoable when it ends (`endLive`).
    func setLive(_ d: EaselDocument) {
        document = d
        view.canvas.sync()
    }

    /// The drag from `before` to now as one undo step.
    func endLive(from before: EaselDocument, name: String) {
        guard document != before else { return }
        document.updatedAt = Date()
        history.record(name, from: before, to: document)
        commit(document, select: nil)
    }

    func undo() {
        var d = document
        guard let e = history.undo(&d) else { return NSSound.beep() }
        commit(d, select: e.touched(forward: false))
        refreshTitle()
    }

    func redo() {
        var d = document
        guard let e = history.redo(&d) else { return NSSound.beep() }
        commit(d, select: e.touched(forward: true))
        refreshTitle()
    }

    private func refreshTitle() {
        if view.titleField.stringValue != document.title { view.titleField.stringValue = document.title }
        store?.renameEaselRows(easelID, to: document.title)
        controller?.easelTitleChanged()
    }

    private func commit(_ d: EaselDocument, select: Set<String>?) {
        document = d
        let ids = Set(d.blocks.map(\.id))
        selection = (select ?? selection).filter(ids.contains)
        view.canvas.sync()
        view.toolbar.refresh()
        scheduleSave()
    }

    /// The title field, as typed: the rows follow at once; no undo step for typing (the field undoes its own).
    func rename(_ title: String) {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EaselDocument.maxTitleLength))
        guard t != document.title else { return }
        document.title = t
        document.updatedAt = Date()
        if view.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != t { view.titleField.stringValue = t }
        store?.renameEaselRows(easelID, to: t)
        controller?.easelTitleChanged()
        scheduleSave()
    }

    /// Where the view looks: kept with the next save, never an undo step.
    func viewportChanged() {
        dirty = true
        scheduleSave(after: 2)
    }

    // MARK: Saving

    private func scheduleSave(after delay: Double = 0.4) {
        dirty = true
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow(wait: false) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Writes the document and its history now (`wait`: before returning, as at quit).
    func saveNow(wait: Bool) {
        saveWork?.cancel()
        saveWork = nil
        guard dirty else { return }
        dirty = false
        document.viewport = view.canvas.viewport
        document.revision = newID()
        history.revision = document.revision
        let doc = document, hist = history, files = EaselCenter.shared.files
        let job = {
            do {
                try files.save(doc)
                try files.saveHistory(hist, id: doc.id)
            } catch {
                NSLog("Airc: couldn't save Easel %@: %@", doc.id, "\(error)")
            }
        }
        if wait {
            Self.saveQueue.sync(execute: job)
        } else {
            Self.saveQueue.async(execute: job)
        }
        saves += 1
    }

    func dismissRecovery() {
        recoveryMessage = nil
        view.showRecovery(nil)
    }

    // MARK: Adding

    /// Adds `content` with `frame`, in front, selected. Its id.
    @discardableResult
    func add(_ content: EaselContent, frame: EaselRect, name: String) -> String {
        let b = EaselBlock(frame: frame, content: content)
        change(name, select: [b.id]) { $0.add(b) }
        return b.id
    }

    /// A text block at `p` (its top left), `width` wide, sized to its text.
    @discardableResult
    func addText(_ text: EaselText, at p: EaselPoint, width: Double = 280, name: String = "Add Text") -> String {
        let h = EaselTextRender.height(text, width: width, look: look)
        return add(.text(text), frame: EaselRect(x: p.x, y: p.y, width: width, height: h), name: name)
    }

    /// A picture centred at `p`, at most 480 points on its long side (Retina pictures at half their pixels).
    @discardableResult
    func addImage(_ image: EaselImage, at p: EaselPoint) -> String {
        let (w, h) = Self.fit(image.pixelWidth / 2, image.pixelHeight / 2, max: 480)
        return add(.image(image), frame: EaselRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), name: "Add Image")
    }

    /// An address as a link card centred at `p`.
    @discardableResult
    func addLink(_ url: URL, title: String? = nil, at p: EaselPoint) -> String {
        let size = EaselLink.defaultSize
        let link = EaselLink(url: url.absoluteString, title: title ?? url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 },
                             detail: url.path.count > 1 ? url.path : nil)
        return add(.link(link), frame: EaselRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height),
                   name: "Add Link")
    }

    /// A Capture (Capture's "Add to Easel"): its picture with the page's address and title, beside what's there; with
    /// `live`, where it came from (P19b: Refresh, Live, Interact).
    @discardableResult
    func addCapture(_ image: EaselImage, url: String?, title: String?, scale: Double = 2, live: EaselLiveSource? = nil) -> String {
        let (w, h) = Self.fit(image.pixelWidth / max(1, scale), image.pixelHeight / max(1, scale), max: 640)
        let x = (document.contentBounds?.maxX ?? -w / 2 - 40) + 40
        let y = document.contentBounds?.minY ?? -h / 2
        let cap = EaselCapture(asset: image.asset, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight, url: url, title: title, capturedAt: Date(),
                               live: live?.isValid == true ? live : nil)
        let id = add(.capture(cap), frame: EaselRect(x: x, y: y, width: w, height: h), name: "Add Capture")
        view.canvas.reveal(EaselRect(x: x, y: y, width: w, height: h))
        return id
    }

    static func fit(_ w: Double, _ h: Double, max m: Double) -> (Double, Double) {
        let w = Swift.max(1, w), h = Swift.max(1, h)
        let s = Swift.min(1, m / Swift.max(w, h))
        return (Swift.max(24, w * s), Swift.max(24, h * s))
    }

    // MARK: Live Captures (P19b, LiveCapture.swift)

    /// The Capture blocks among `ids` (default: the selection) that have a live source.
    func liveIDs(_ ids: Set<String>? = nil) -> [String] {
        let want = ids ?? selection
        return document.liveBlocks.map(\.id).filter { want.contains($0) }
    }

    /// Refresh: blocks `ids` (nil: every live Capture on the Easel, ⌘R) taken again now.
    func refreshLive(_ ids: [String]? = nil) {
        let list = ids ?? document.liveBlocks.map(\.id)
        guard !list.isEmpty else { return NSSound.beep() }
        EaselLiveCenter.shared.refresh(self, list, manual: true)
    }

    /// Live ↔ Manual for the selection's live Captures (one undo step).
    func setLiveMode(_ m: EaselLiveSource.Mode) {
        let ids = liveIDs()
        guard !ids.isEmpty else { return }
        change(m == .live ? "Update Automatically" : "Update Manually") { d in for id in ids { d.setLiveMode(m, for: id) } }
        if m == .live { EaselLiveCenter.shared.shown(self) }
    }

    /// Detach: the selection's live Captures become plain pictures (one undo step); a refresh under way stops.
    func detachLive() {
        let ids = liveIDs()
        guard !ids.isEmpty else { return }
        for id in ids { EaselLiveCenter.shared.cancel(easelID: easelID, blockID: id) }
        change("Detach") { d in for id in ids { d.setLive(nil, for: id) } }
    }

    /// A refresh ended: its outcome lands (no undo step; the history's steps take the new picture), unless the block was
    /// detached, deleted or re-captured meanwhile.
    func applyLive(_ o: EaselLiveOutcome, blockID: String, sourceID: String) {
        var d = document
        guard d.applyLive(o, blockID: blockID, sourceID: sourceID), let b = d.block(blockID) else { return }
        history.carryLive(of: b)
        document = d
        view.canvas.sync()
        scheduleSave()
    }

    /// A Capture's source, arrived just after the block (the page said where it was): set without an undo step of its
    /// own, as part of the Add.
    func attachLive(_ s: EaselLiveSource, to blockID: String) {
        var d = document
        guard d.liveSource(blockID) == nil, d.setLive(s, for: blockID) else { return }
        history.attachLive(s, to: blockID)
        document = d
        view.canvas.sync()
        scheduleSave()
    }

    /// The blocks being refreshed now (their chips say so).
    var refreshing: Set<String> {
        Set(document.liveBlocks.map(\.id).filter { EaselLiveCenter.shared.isRefreshing(easelID, $0) })
    }

    func refreshingChanged() { view?.canvas.sync() }

    // MARK: Editing the selection

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        for id in liveIDs() { EaselLiveCenter.shared.cancel(easelID: easelID, blockID: id) }
        change("Delete", select: []) { $0.remove(selection) }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        var made: [String] = []
        change("Duplicate") { made = $0.duplicate(selection) }
        selection = Set(made)
    }

    func groupSelection() {
        guard selection.count >= 2 else { return NSSound.beep() }
        change("Group") { $0.group(selection) }
    }

    func ungroupSelection() {
        guard document.blocks.contains(where: { selection.contains($0.id) && $0.group != nil }) else { return NSSound.beep() }
        change("Ungroup") { $0.ungroup(selection) }
    }

    func nudge(_ dx: Double, _ dy: Double) {
        guard !selection.isEmpty else { return }
        change("Move") { $0.move(selection, dx: dx, dy: dy) }
    }

    func restack(_ how: String) {
        guard !selection.isEmpty else { return }
        change(how) { d in
            switch how {
            case "Bring to Front": d.bringToFront(selection)
            case "Send to Back": d.sendToBack(selection)
            case "Bring Forward": d.bringForward(selection)
            default: d.sendBackward(selection)
            }
        }
    }

    /// A colour for the selection: shapes' fill, lines', texts'.
    func setColor(_ c: EaselColor?) {
        change("Color") { d in
            for id in selection {
                d.update(id) { b in
                    switch b.content {
                    case .shape(var s): s.fill = c; b.content = .shape(s)
                    case .line(var l): if let c { l.color = c; b.setLine(l) }
                    case .text(var t): t.color = c; b.content = .text(t)
                    default: break
                    }
                }
            }
        }
        if let c { Self.lastFill = c; Self.lastLineColor = c }
    }

    func setFont(_ f: EaselFont) {
        Self.lastFont = f
        restyleText("Font") { $0.font = f }
    }

    func setTextSize(_ s: Double) {
        Self.lastTextSize = s
        restyleText("Text Size") { $0.size = s }
    }

    func setAlignment(_ a: EaselAlignment) { restyleText("Alignment") { $0.alignment = a } }

    private func restyleText(_ name: String, _ body: (inout EaselText) -> Void) {
        let l = look
        change(name) { d in
            for id in selection {
                d.update(id) { b in
                    guard case .text(var t) = b.content else { return }
                    body(&t)
                    b.content = .text(t)
                    b.frame.height = EaselTextRender.height(t, width: b.frame.width, look: l)
                }
            }
        }
    }

    // MARK: Clipboard

    static let blocksType = NSPasteboard.PasteboardType("org.airc.easel.blocks")
    /// Tests use a private pasteboard (the person's clipboard is never touched).
    static var pasteboard: () -> NSPasteboard = { .general }

    private struct Clip: Codable {
        var source: String
        var blocks: [EaselBlock]
    }

    func copySelection() {
        let blocks = document.stacked.filter { selection.contains($0.id) }
        guard !blocks.isEmpty, let data = try? JSONEncoder().encode(Clip(source: easelID, blocks: blocks)) else { return }
        let pb = Self.pasteboard()
        pb.clearContents()
        pb.setData(data, forType: Self.blocksType)
        let texts = blocks.compactMap { b -> String? in
            switch b.content {
            case .text(let t): t.plainText
            case .link(let l): l.url
            case .capture(let c): c.url
            default: nil
            }
        }
        if !texts.isEmpty { pb.setString(texts.joined(separator: "\n"), forType: .string) }
        if blocks.count == 1, let asset = blocks[0].content.assets.first, let url = EaselCenter.shared.files.assetURL(easelID, asset),
           let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
    }

    func cutSelection() {
        copySelection()
        guard !selection.isEmpty else { return }
        change("Cut", select: []) { $0.remove(selection) }
    }

    /// Paste: Easel blocks (from this Easel or another, their pictures with them), else pictures, else an address (a
    /// link card), else text (a text block). At `p`, or the middle of the view.
    func paste(at p: EaselPoint? = nil) {
        let pb = Self.pasteboard()
        let at = p ?? view.canvas.visibleCenter
        if let data = pb.data(forType: Self.blocksType), let clip = try? JSONDecoder().decode(Clip.self, from: data), !clip.blocks.isEmpty {
            EaselCenter.shared.files.copyAssets(Set(clip.blocks.flatMap(\.content.assets)), from: clip.source, to: easelID)
            var made: [String] = []
            // From this Easel: beside the originals. From another: centred where it's pasted.
            var offset = EaselMetrics.copyOffset
            var blocks = clip.blocks
            if clip.source != easelID || p != nil, let box = blocks.map(\.bounds).reduce(nil as EaselRect?, { $0?.union($1) ?? $1 }) {
                blocks = blocks.map { $0.offsetBy(dx: at.x - box.midX, dy: at.y - box.midY) }
                offset = 0
            }
            change("Paste") { made = $0.insert(copies: blocks, offset: offset) }
            selection = Set(made)
            return
        }
        let images = EaselCenter.shared.readPictures(pb, into: easelID)
        if !images.isEmpty {
            var q = at
            var made: Set<String> = []
            for i in images {
                made.insert(addImage(i, at: q))
                q = q.offsetBy(dx: 30, dy: 30)
            }
            selection = made
            return
        }
        let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let u = Self.webURL(s) {
            addLink(u, at: at)
        } else if !s.isEmpty {
            let t = EaselText(plain: s, font: Self.lastFont, size: Self.lastTextSize)
            addText(t, at: EaselPoint(at.x - 160, at.y - 20), width: 320, name: "Paste")
        }
    }

    static func webURL(_ s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace), let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }
}

// MARK: - The Easel's view

/// The card's Easel: the canvas filling it, its title floating at the top left, the tools floating at the bottom,
/// the zoom at the bottom right, and a bar when a damaged file was opened.
final class EaselEditorView: NSView, NSTextFieldDelegate {
    weak var editor: EaselEditor?
    let easelID: String
    let titleField = NSTextField()
    let canvas: EaselCanvasView
    let toolbar: EaselToolbar
    let zoomBar: EaselZoomBar
    private let banner = NSView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let bannerClose = NSButton()
    private(set) var look = EaselLook(palette: .chill, dark: false)
    var cornerRadius: CGFloat = 0 { didSet { layer?.cornerRadius = cornerRadius } }

    /// P19b: the Easel leaving the card ends an interaction with one of its Captures (its page goes too).
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, let i = EaselInteraction.current, i.editor === editor { i.end(capture: false) }
        super.viewWillMove(toSuperview: newSuperview)
    }

    init(editor: EaselEditor) {
        self.editor = editor
        easelID = editor.easelID
        canvas = EaselCanvasView(editor: editor)
        toolbar = EaselToolbar(editor: editor)
        zoomBar = EaselZoomBar(canvas: canvas)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        wantsLayer = true
        layer?.masksToBounds = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.placeholderString = EaselURL.untitled
        titleField.delegate = self
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.setAccessibilityLabel("Easel Title")
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 10
        banner.isHidden = true
        bannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        bannerLabel.isSelectable = false
        bannerClose.bezelStyle = .inline
        bannerClose.isBordered = false
        bannerClose.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        bannerClose.target = self
        bannerClose.action = #selector(closeBanner)
        banner.addSubview(bannerLabel)
        banner.addSubview(bannerClose)
        for v in [canvas, titleField, toolbar, zoomBar, banner] as [NSView] { addSubview(v) }
        setAccessibilityIdentifier("easel.editor")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func apply(_ l: EaselLook, palette: Palette, cornerRadius r: CGFloat) {
        cornerRadius = r
        appearance = NSAppearance(named: l.dark ? .darkAqua : .aqua)
        titleField.textColor = l.ink
        banner.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.84, blue: 0.4, alpha: l.dark ? 0.25 : 0.55).cgColor
        bannerLabel.textColor = l.ink
        toolbar.apply(palette)
        zoomBar.apply(palette)
        guard l != look else { return }
        look = l
        layer?.backgroundColor = l.background.cgColor
        canvas.lookChanged()
    }

    func showRecovery(_ message: String?) {
        banner.isHidden = message == nil
        bannerLabel.stringValue = message ?? ""
        needsLayout = true
    }

    @objc private func closeBanner() { editor?.dismissRecovery() }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        titleField.frame = NSRect(x: 22, y: 16, width: min(520, max(0, bounds.width - 220)), height: 28)
        let tb = toolbar.fittingSize
        toolbar.frame = NSRect(x: ((bounds.width - tb.width) / 2).rounded(), y: bounds.height - tb.height - 16, width: tb.width, height: tb.height)
        let zb = zoomBar.fittingSize
        zoomBar.frame = NSRect(x: bounds.width - zb.width - 16, y: bounds.height - zb.height - 16, width: zb.width, height: zb.height)
        let bw = min(560, bounds.width - 40)
        let bh = max(36, bannerLabel.sizeThatFits(NSSize(width: bw - 52, height: 200)).height + 16)
        banner.frame = NSRect(x: (bounds.width - bw) / 2, y: 54, width: bw, height: bh)
        bannerLabel.frame = NSRect(x: 14, y: 8, width: bw - 52, height: bh - 16)
        bannerClose.frame = NSRect(x: bw - 32, y: (bh - 20) / 2, width: 20, height: 20)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        editor?.rename(titleField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        editor?.rename(titleField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === titleField else { return false }
        if sel == #selector(insertNewline(_:)) || sel == #selector(cancelOperation(_:)) || sel == #selector(insertTab(_:)) {
            editor?.rename(titleField.stringValue)
            window?.makeFirstResponder(canvas)
            return true
        }
        return false
    }
}

// MARK: - The tools

enum EaselTool: String, CaseIterable {
    case select, hand, text, rectangle, ellipse, arrow, line

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        }
    }

    var title: String {
        switch self {
        case .select: "Select (V)"
        case .hand: "Hand (H, or hold Space)"
        case .text: "Text (T)"
        case .rectangle: "Rectangle (R)"
        case .ellipse: "Ellipse (O)"
        case .arrow: "Arrow (A)"
        case .line: "Line (L)"
        }
    }

    /// Its key on the canvas.
    var key: String {
        switch self {
        case .select: "v"
        case .hand: "h"
        case .text: "t"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        }
    }
}

/// A small round button with a symbol (the toolbar's and the zoom bar's).
final class EaselToolButton: NSButton {
    var selectedFill: NSColor = .controlAccentColor
    var isOn = false { didSet { refresh() } }
    var palette: Palette? { didSet { refresh() } }

    init(symbol: String, tip: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        toolTip = tip
        setAccessibilityLabel(tip)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    private func refresh() {
        layer?.backgroundColor = isOn ? (palette?.selected ?? NSColor.selectedControlColor).cgColor : NSColor.clear.cgColor
        contentTintColor = palette?.textPrimary
    }
}

final class EaselToolbar: NSView {
    private weak var editor: EaselEditor?
    private var toolButtons: [EaselTool: EaselToolButton] = [:]
    private var extra: [EaselToolButton] = []
    private let stack = NSStackView()
    private var palette: Palette?

    init(editor: EaselEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        for t in EaselTool.allCases {
            let b = EaselToolButton(symbol: t.symbol, tip: t.title, target: self, action: #selector(pickTool(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(sep)
        for (symbol, tip, action) in [("photo", "Add Image…", #selector(chooseImage)), ("link", "Add Link…", #selector(askLink)),
                                      ("paintpalette", "Color", #selector(colorMenu(_:))), ("textformat.size", "Text Style", #selector(fontMenu(_:)))] {
            let b = EaselToolButton(symbol: symbol, tip: tip, target: self, action: action)
            extra.append(b)
            stack.addArrangedSubview(b)
        }
        // P19c: Share and Export (Easels/EaselSharing.swift).
        let share = EaselToolButton(symbol: "square.and.arrow.up", tip: "Share and Export", target: self, action: #selector(shareMenu(_:)))
        share.setAccessibilityIdentifier("easel.share")
        extra.append(share)
        stack.addArrangedSubview(share)
        addSubview(stack)
        setAccessibilityIdentifier("easel.toolbar")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { stack.fittingSize }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    func apply(_ p: Palette) {
        palette = p
        layer?.backgroundColor = p.panelBackground.cgColor
        layer?.borderColor = p.panelBorder.cgColor
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowColor = NSColor(white: 0, alpha: p.isDark ? 0.45 : 0.14).cgColor
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        for b in toolButtons.values { b.palette = p }
        for b in extra { b.palette = p }
    }

    func refresh() {
        let tool = editor?.view?.canvas.tool ?? .select
        for (t, b) in toolButtons { b.isOn = t == tool }
    }

    func button(_ t: EaselTool) -> NSButton? { toolButtons[t] }

    @objc private func pickTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let t = EaselTool(rawValue: raw) else { return }
        editor?.view.canvas.tool = t
        editor?.focus()
    }

    @objc private func chooseImage() {
        guard let editor, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            var p = editor.view.canvas.visibleCenter
            var made: Set<String> = []
            for u in panel.urls {
                guard let data = try? Data(contentsOf: u), let img = EaselCenter.shared.storePicture(data, ext: u.pathExtension, in: editor.easelID) else { continue }
                made.insert(editor.addImage(img, at: p))
                p = p.offsetBy(dx: 30, dy: 30)
            }
            if !made.isEmpty { editor.selection = made }
            editor.focus()
        }
    }

    @objc private func askLink() {
        guard let editor, let window else { return }
        let a = NSAlert()
        a.messageText = "Add a Link"
        a.informativeText = "The address of the page."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://"
        a.accessoryView = field
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            var s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, !s.contains("://") { s = "https://" + s }
            if let u = EaselEditor.webURL(s) { editor.addLink(u, at: editor.view.canvas.visibleCenter) } else { NSSound.beep() }
            editor.focus()
        }
    }

    @objc private func colorMenu(_ sender: NSButton) {
        let m = NSMenu()
        for c in EaselColor.allCases {
            let i = NSMenuItem(title: c.displayName, action: #selector(pickColor(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = c.rawValue
            i.image = swatch(c)
            m.addItem(i)
        }
        m.addItem(.separator())
        let none = NSMenuItem(title: "No Fill", action: #selector(pickColor(_:)), keyEquivalent: "")
        none.target = self
        m.addItem(none)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// P19c: the toolbar's Share and Export menu.
    @objc private func shareMenu(_ sender: NSButton) {
        guard let editor else { return }
        let m = NSMenu()
        let empty = editor.document.isEmpty
        for (title, action) in [("Share Link…", #selector(menuShareLink)), ("Share…", #selector(menuSharePicture(_:))),
                                (editor.selection.isEmpty ? "Copy Easel as Image" : "Copy as Image", #selector(menuCopyImage)),
                                ("Export as Image…", #selector(menuExportImage)), ("Export as Web Page…", #selector(menuExportWebPage))] {
            if title == "Export as Image…" { m.addItem(.separator()) }
            let i = NSMenuItem(title: title, action: empty ? nil : action, keyEquivalent: "")
            i.target = self
            i.representedObject = sender
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuShareLink() { editor?.shareLink() }
    @objc private func menuSharePicture(_ sender: NSMenuItem) { editor?.sharePicture(from: sender.representedObject as? NSView) }
    @objc private func menuCopyImage() { editor?.copyImage() }
    @objc private func menuExportImage() { editor?.export(.image) }
    @objc private func menuExportWebPage() { editor?.export(.webPage) }

    private func swatch(_ c: EaselColor) -> NSImage {
        let look = editor?.look ?? EaselLook(palette: .chill, dark: false)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            look.color(c).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0, alpha: 0.15).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        let c = (sender.representedObject as? String).flatMap(EaselColor.init(rawValue:))
        if let c { EaselEditor.lastFill = c; EaselEditor.lastLineColor = c }
        editor?.setColor(c)
    }

    @objc private func fontMenu(_ sender: NSButton) {
        let m = NSMenu()
        for (f, name) in [(EaselFont.clean, "Clean"), (.mono, "Mono"), (.fancy, "Fancy"), (.hip, "Hip")] {
            let i = NSMenuItem(title: name, action: #selector(pickFont(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = f.rawValue
            i.state = EaselEditor.lastFont == f ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        for (size, name) in [(13.0, "Small"), (17.0, "Body"), (28.0, "Large"), (44.0, "Heading"), (72.0, "Huge")] {
            let i = NSMenuItem(title: name, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = size
            i.state = EaselEditor.lastTextSize == size ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        for (a, name) in [(EaselAlignment.left, "Align Left"), (.center, "Align Center"), (.right, "Align Right")] {
            let i = NSMenuItem(title: name, action: #selector(pickAlignment(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = a.rawValue
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pickFont(_ sender: NSMenuItem) {
        if let f = (sender.representedObject as? String).flatMap(EaselFont.init(rawValue:)) { editor?.setFont(f) }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { editor?.setTextSize(s) }
    }

    @objc private func pickAlignment(_ sender: NSMenuItem) {
        if let a = (sender.representedObject as? String).flatMap(EaselAlignment.init(rawValue:)) { editor?.setAlignment(a) }
    }
}

/// − 100 % + and Fit, at the bottom right.
final class EaselZoomBar: NSView {
    private weak var canvas: EaselCanvasView?
    private let label = NSButton(title: "100%", target: nil, action: nil)
    private var buttons: [EaselToolButton] = []
    private let stack = NSStackView()

    init(canvas: EaselCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        let minus = EaselToolButton(symbol: "minus", tip: "Zoom Out (⌘−)", target: self, action: #selector(zoomOut))
        let plus = EaselToolButton(symbol: "plus", tip: "Zoom In (⌘+)", target: self, action: #selector(zoomIn))
        let fit = EaselToolButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", tip: "Zoom to Fit (⇧1)", target: self, action: #selector(fit))
        label.isBordered = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.target = self
        label.action = #selector(actual)
        label.toolTip = "Actual Size (⌘0)"
        label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        buttons = [minus, plus, fit]
        for v in [minus, label, plus, fit] as [NSView] { stack.addArrangedSubview(v) }
        addSubview(stack)
        setAccessibilityIdentifier("easel.zoom")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { stack.fittingSize }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    func apply(_ p: Palette) {
        layer?.backgroundColor = p.panelBackground.cgColor
        layer?.borderColor = p.panelBorder.cgColor
        layer?.borderWidth = 0.5
        label.contentTintColor = p.textPrimary
        for b in buttons { b.palette = p }
    }

    func zoomChanged(_ z: Double) { label.title = "\(Int((z * 100).rounded()))%" }

    @objc private func zoomIn() { canvas?.zoomStep(in: true) }
    @objc private func zoomOut() { canvas?.zoomStep(in: false) }
    @objc private func fit() { canvas?.zoomToFit(animated: true) }
    @objc private func actual() { canvas?.setZoom(1, about: nil, animated: true) }
}

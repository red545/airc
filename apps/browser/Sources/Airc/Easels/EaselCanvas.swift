// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import QuartzCore

/// A view that keeps its own keys while it has the keyboard: the key monitor (App/Commands.swift) lets them through to
/// it instead of running the browser's command for them (⌘Z isn't Reopen Closed Tab on an Easel, ⌘D isn't Pin).
protocol EaselKeyOwner: AnyObject {
    func claims(_ event: NSEvent) -> Bool
}

/// The Easel's canvas: an endless plane in points (y down), panned and zoomed by one transform on `world`, with one
/// layer per block (EaselRender.swift). The selection, its handles, snap guides and the marquee are drawn above it in
/// view coordinates. Layer-hosting: AppKit leaves the layer tree alone, and the root is geometry-flipped by us.
final class EaselCanvasView: NSView, EaselKeyOwner, NSMenuItemValidation, NSTextViewDelegate {
    weak var editor: EaselEditor?
    private let root = CALayer()
    private let world = CALayer()
    private var blockLayers: [String: EaselBlockLayer] = [:]
    private let selectionLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let guidesLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()

    /// The plane point at the view's top left, and the zoom.
    private(set) var origin = EaselPoint(-400, -300)
    private(set) var zoom: Double = 1
    var tool: EaselTool = .select {
        didSet {
            editor?.view?.toolbar.refresh()
            window?.invalidateCursorRects(for: self)
        }
    }
    private var spaceHeld = false
    private var guides: [EaselSnapping.Guide] = []
    private var marquee: EaselRect?
    private var scaleWork: DispatchWorkItem?
    private var appliedScale: CGFloat = 0
    /// Frames drawn in the last pan measurement (the perf check).
    private(set) var textEditor: EaselTextView?
    private var editingID: String?
    private var editingBefore: EaselDocument?

    private var document: EaselDocument { editor?.document ?? EaselDocument() }
    private var selection: Set<String> {
        get { editor?.selection ?? [] }
        set { editor?.selection = newValue }
    }
    var look: EaselLook { editor?.view?.look ?? EaselLook(palette: .chill, dark: false) }

    init(editor: EaselEditor) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        root.isGeometryFlipped = true
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        world.anchorPoint = .zero
        world.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        world.position = .zero
        world.actions = ["transform": NSNull(), "sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
        root.addSublayer(world)
        for l in [selectionLayer, handlesLayer, guidesLayer, marqueeLayer] {
            l.fillColor = nil
            l.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
            l.anchorPoint = .zero
            l.position = .zero
            root.addSublayer(l)
        }
        selectionLayer.lineWidth = 1.5
        handlesLayer.lineWidth = 1.25
        guidesLayer.lineWidth = 1
        guidesLayer.lineDashPattern = [4, 3]
        marqueeLayer.lineWidth = 1
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string, NSPasteboard.PasteboardType("public.url"),
                                 NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), EaselEditor.blocksType])
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Easel canvas")
        lookChanged()
        applyTransform()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Coordinates

    func view(_ p: EaselPoint) -> NSPoint { NSPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom) }
    func plane(_ p: NSPoint) -> EaselPoint { EaselPoint(Double(p.x) / zoom + origin.x, Double(p.y) / zoom + origin.y) }
    func plane(_ e: NSEvent) -> EaselPoint { plane(convert(e.locationInWindow, from: nil)) }
    func viewRect(_ r: EaselRect) -> NSRect {
        let a = view(EaselPoint(r.minX, r.minY))
        return NSRect(x: a.x, y: a.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// The plane the view shows.
    var visibleRect_: EaselRect {
        EaselRect(x: origin.x, y: origin.y, width: Double(bounds.width) / zoom, height: Double(bounds.height) / zoom)
    }

    var visibleCenter: EaselPoint { EaselPoint(origin.x + Double(bounds.width) / zoom / 2, origin.y + Double(bounds.height) / zoom / 2) }

    var viewport: EaselViewport { EaselViewport(centerX: visibleCenter.x, centerY: visibleCenter.y, zoom: zoom) }

    /// For the check: a plane point in window coordinates.
    func windowPoint(plane p: EaselPoint) -> NSPoint { convert(view(p), to: nil) }

    private var lastSize: NSSize = .zero

    override func layout() {
        super.layout()
        // Resizing keeps the middle where it was.
        if lastSize != .zero, lastSize != bounds.size {
            origin = origin.offsetBy(dx: Double(lastSize.width - bounds.width) / zoom / 2, dy: Double(lastSize.height - bounds.height) / zoom / 2)
        }
        lastSize = bounds.size
        applyTransform()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        root.contentsScale = window?.backingScaleFactor ?? 2
        appliedScale = 0
        settleScale()
    }

    func restoreViewport(_ v: EaselViewport?) {
        if let v, v.zoom.isFinite, v.centerX.isFinite, v.centerY.isFinite {
            zoom = min(EaselMetrics.maximumZoom, max(EaselMetrics.minimumZoom, v.zoom))
            origin = EaselPoint(v.centerX - Double(bounds.width) / zoom / 2, v.centerY - Double(bounds.height) / zoom / 2)
        } else if let box = document.contentBounds {
            origin = EaselPoint(box.midX - Double(bounds.width) / 2, box.midY - Double(bounds.height) / 2)
        } else {
            origin = EaselPoint(-Double(bounds.width) / 2, -Double(bounds.height) / 2)
        }
        applyTransform()
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.setAffineTransform(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: -origin.x * zoom, ty: -origin.y * zoom))
        updateOverlay()
        CATransaction.commit()
        editor?.view?.zoomBar.zoomChanged(zoom)
        updateTextEditorFrame()
    }

    /// Pans by `dx, dy` view points (content moves with the fingers).
    func pan(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        origin = origin.offsetBy(dx: -dx / zoom, dy: -dy / zoom)
        applyTransform()
        settleScale(after: 0.25)
        editor?.viewportChanged()
    }

    func setZoom(_ z: Double, about anchor: NSPoint?, animated: Bool = false) {
        let target = min(EaselMetrics.maximumZoom, max(EaselMetrics.minimumZoom, z))
        let a = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let fixed = plane(a)
        guard animated, abs(target - zoom) > 0.001 else {
            zoom = target
            origin = EaselPoint(fixed.x - Double(a.x) / zoom, fixed.y - Double(a.y) / zoom)
            applyTransform()
            settleScale()
            editor?.viewportChanged()
            return
        }
        animate(toZoom: target, center: nil, anchor: a, fixed: fixed)
    }

    private var animation: Timer?

    /// A short ease-out to a zoom (and a centre, for Fit), at the display's rate.
    private func animate(toZoom target: Double, center: EaselPoint?, anchor: NSPoint, fixed: EaselPoint) {
        animation?.invalidate()
        let z0 = zoom, o0 = origin, t0 = CACurrentMediaTime(), d = 0.22
        let o1: EaselPoint = center.map { EaselPoint($0.x - Double(bounds.width) / target / 2, $0.y - Double(bounds.height) / target / 2) }
            ?? EaselPoint(fixed.x - Double(anchor.x) / target, fixed.y - Double(anchor.y) / target)
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let f = min(1, (CACurrentMediaTime() - t0) / d)
            let e = 1 - pow(1 - f, 3)
            // Interpolate the zoom geometrically and the view's middle linearly, so the move reads as one.
            self.zoom = z0 * pow(target / z0, e)
            if center != nil {
                let c0 = EaselPoint(o0.x + Double(self.bounds.width) / z0 / 2, o0.y + Double(self.bounds.height) / z0 / 2)
                let c1 = EaselPoint(o1.x + Double(self.bounds.width) / target / 2, o1.y + Double(self.bounds.height) / target / 2)
                let c = EaselPoint(c0.x + (c1.x - c0.x) * e, c0.y + (c1.y - c0.y) * e)
                self.origin = EaselPoint(c.x - Double(self.bounds.width) / self.zoom / 2, c.y - Double(self.bounds.height) / self.zoom / 2)
            } else {
                self.origin = EaselPoint(fixed.x - Double(anchor.x) / self.zoom, fixed.y - Double(anchor.y) / self.zoom)
            }
            self.applyTransform()
            if f >= 1 {
                timer.invalidate()
                self.animation = nil
                self.settleScale()
                self.editor?.viewportChanged()
            }
        }
        animation = t
        RunLoop.main.add(t, forMode: .common)
    }

    func zoomStep(in: Bool) {
        let steps: [Double] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 3, 4, 6, 8]
        let next = `in` ? steps.first { $0 > zoom + 0.001 } ?? 8 : steps.last { $0 < zoom - 0.001 } ?? 0.1
        setZoom(next, about: nil, animated: true)
    }

    /// Everything on the Easel in view (at most 100 %), or the selection's when there is one (⇧2).
    func zoomToFit(animated: Bool, selectionOnly: Bool = false) {
        let blocks = selectionOnly ? document.blocks.filter { selection.contains($0.id) } : document.blocks
        guard let box = blocks.map(\.bounds).reduce(nil as EaselRect?, { $0?.union($1) ?? $1 }) else {
            return setZoom(1, about: nil, animated: animated)
        }
        let margin: Double = 80
        let z = min(1, max(EaselMetrics.minimumZoom, min((Double(bounds.width) - 2 * margin) / max(1, box.width),
                                                           (Double(bounds.height) - 2 * margin) / max(1, box.height))))
        if animated {
            animate(toZoom: z, center: box.center, anchor: .zero, fixed: box.center)
        } else {
            zoom = z
            origin = EaselPoint(box.midX - Double(bounds.width) / z / 2, box.midY - Double(bounds.height) / z / 2)
            applyTransform()
            settleScale()
        }
    }

    /// Centres plane point `p` at zoom `z`, at once (a live Capture's interaction).
    func center(on p: EaselPoint, zoom z: Double) {
        animation?.invalidate()
        animation = nil
        zoom = min(EaselMetrics.maximumZoom, max(EaselMetrics.minimumZoom, z))
        origin = EaselPoint(p.x - Double(bounds.width) / zoom / 2, p.y - Double(bounds.height) / zoom / 2)
        applyTransform()
        settleScale()
        editor?.viewportChanged()
    }

    /// Brings `r` into view (a new Capture), panning only.
    func reveal(_ r: EaselRect) {
        let v = visibleRect_
        guard !(r.minX >= v.minX && r.maxX <= v.maxX && r.minY >= v.minY && r.maxY <= v.maxY) else { return }
        animate(toZoom: zoom, center: r.center, anchor: .zero, fixed: r.center)
    }

    /// Once a zoom settles: block contents redrawn at a scale that's sharp at it (powers of two), visible ones first.
    private func settleScale(after delay: Double = 0.12) {
        scaleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applyContentsScale() }
        scaleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private var wantedScale: CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        let bucket = pow(2, ceil(log2(max(0.25, zoom))))
        return backing * CGFloat(min(4, max(0.5, bucket)))
    }

    private func applyContentsScale() {
        let s = wantedScale
        let visible = visibleRect_.insetBy(-200 / zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, l) in blockLayers where l.contentsScale != s {
            guard let b = document.block(id), b.bounds.intersects(visible) else { continue }
            l.contentsScale = s
            l.setNeedsDisplay()
        }
        CATransaction.commit()
        appliedScale = s
    }

    // MARK: Showing the document

    func lookChanged() {
        let l = look
        let accent = l.accent.cgColor
        selectionLayer.strokeColor = accent
        handlesLayer.strokeColor = accent
        handlesLayer.fillColor = NSColor.white.cgColor
        guidesLayer.strokeColor = NSColor(srgbRed: 0.98, green: 0.24, blue: 0.48, alpha: 1).cgColor
        marqueeLayer.strokeColor = accent
        marqueeLayer.fillColor = l.accent.withAlphaComponent(0.08).cgColor
        for layer in blockLayers.values { layer.update(layer.block, look: l) }
    }

    /// The layers follow the document: new blocks get one, gone blocks lose theirs, changed ones are placed or redrawn.
    func sync() {
        let d = document
        let l = look
        let scale = appliedScale > 0 ? appliedScale : wantedScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        let refreshing = editor?.refreshing ?? []
        for (i, b) in d.stacked.enumerated() {
            seen.insert(b.id)
            if let layer = blockLayers[b.id] {
                if layer.block != b || layer.look != l { layer.update(b, look: l) }
                layer.zPosition = CGFloat(i)
            } else {
                let layer = EaselBlockLayer(block: b, look: l, easelID: d.id)
                layer.contentsScale = scale
                layer.drawsAsynchronously = true
                layer.zPosition = CGFloat(i)
                world.addSublayer(layer)
                layer.setNeedsDisplay()
                blockLayers[b.id] = layer
            }
        }
        for (id, layer) in blockLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            blockLayers[id] = nil
        }
        if let id = editingID { blockLayers[id]?.hidesText = true }
        for (id, layer) in blockLayers { layer.refreshing = refreshing.contains(id) }
        updateOverlay()
        CATransaction.commit()
    }

    func selectionChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateOverlay()
        CATransaction.commit()
    }

    var layerCount: Int { blockLayers.count }

    // MARK: The selection's frame and handles

    /// What the handles frame: one block's own (turned) frame, or the box around several.
    private struct Box {
        var rect: EaselRect
        var rotation: Double
        var single: EaselBlock?
    }

    private func selectionBox() -> Box? {
        let sel = document.blocks.filter { selection.contains($0.id) }
        guard !sel.isEmpty else { return nil }
        // A group (or one block) turned as one keeps its turn.
        if sel.count == 1 { return Box(rect: sel[0].frame, rotation: sel[0].rotation, single: sel[0]) }
        let box = sel.map(\.bounds).reduce(sel[0].bounds) { $0.union($1) }
        return Box(rect: box, rotation: 0, single: nil)
    }

    enum Handle: Equatable {
        /// Resizing: which edges move (−1 left/top, 1 right/bottom, 0 neither).
        case resize(x: Int, y: Int)
        case rotate
        case lineStart, lineEnd
    }

    /// The handles of the selection, in view coordinates.
    private func handles() -> [(Handle, NSPoint)] {
        guard let box = selectionBox() else { return [] }
        if let b = box.single, let l = b.line { return [(.lineStart, view(l.from)), (.lineEnd, view(l.to))] }
        let r = box.rect, c = r.center
        var out: [(Handle, NSPoint)] = []
        let small = r.width * zoom < 24 || r.height * zoom < 24
        for y in -1...1 {
            for x in -1...1 where !(x == 0 && y == 0) {
                if small, x == 0 || y == 0 { continue }
                let p = EaselPoint(r.midX + Double(x) * r.width / 2, r.midY + Double(y) * r.height / 2)
                out.append((.resize(x: x, y: y), view(EaselGeometry.rotate(p, about: c, by: box.rotation))))
            }
        }
        if box.single != nil, !(box.single?.content.isLine ?? false) {
            let top = EaselPoint(r.midX, r.minY - 22 / zoom)
            out.append((.rotate, view(EaselGeometry.rotate(top, about: c, by: box.rotation))))
        }
        return out
    }

    private func handle(at p: NSPoint) -> Handle? {
        handles().first { hypot($0.1.x - p.x, $0.1.y - p.y) <= 7 }?.0
    }

    private func path(_ r: EaselRect, rotation: Double) -> CGPath {
        let c = r.center
        let corners = [EaselPoint(r.minX, r.minY), EaselPoint(r.maxX, r.minY), EaselPoint(r.maxX, r.maxY), EaselPoint(r.minX, r.maxY)]
            .map { view(EaselGeometry.rotate($0, about: c, by: rotation)) }
        let p = CGMutablePath()
        p.addLines(between: corners)
        p.closeSubpath()
        return p
    }

    private func updateOverlay() {
        let sel = document.blocks.filter { selection.contains($0.id) }
        let outline = CGMutablePath()
        if sel.count > 1 {
            for b in sel where b.line == nil { outline.addPath(path(b.frame, rotation: b.rotation)) }
        }
        if let box = selectionBox() {
            if let b = box.single, let l = b.line {
                outline.move(to: view(l.from))
                outline.addLine(to: view(l.to))
            } else {
                outline.addPath(path(box.rect, rotation: box.rotation))
            }
        }
        selectionLayer.path = outline
        selectionLayer.isHidden = sel.isEmpty || editingID != nil
        let hp = CGMutablePath()
        for (h, p) in handles() {
            if h == .rotate {
                hp.addEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            } else {
                hp.addRoundedRect(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8), cornerWidth: 2, cornerHeight: 2)
            }
        }
        handlesLayer.path = hp
        handlesLayer.isHidden = sel.isEmpty || editingID != nil
        let gp = CGMutablePath()
        for g in guides {
            switch g.axis {
            case .vertical:
                gp.move(to: view(EaselPoint(g.at, g.from)))
                gp.addLine(to: view(EaselPoint(g.at, g.to)))
            case .horizontal:
                gp.move(to: view(EaselPoint(g.from, g.at)))
                gp.addLine(to: view(EaselPoint(g.to, g.at)))
            }
        }
        guidesLayer.path = gp
        if let m = marquee {
            marqueeLayer.path = CGPath(rect: viewRect(m), transform: nil)
            marqueeLayer.isHidden = false
        } else {
            marqueeLayer.isHidden = true
        }
    }

    /// What snap guides showed during the last drag (the check reads it).
    private(set) var lastGuides: [EaselSnapping.Guide] = []

    // MARK: Mouse

    private enum Drag {
        case pan(last: NSPoint)
        case move(start: EaselPoint, before: EaselDocument, ids: Set<String>, box: EaselRect, others: [EaselRect], name: String)
        case resize(handle: Handle, start: EaselPoint, before: EaselDocument, box: Box, ids: Set<String>, others: [EaselRect])
        case rotate(start: EaselPoint, before: EaselDocument, center: EaselPoint, ids: Set<String>)
        case lineEnd(start: Bool, before: EaselDocument, id: String)
        case marquee(start: EaselPoint, initial: Set<String>)
        case create(tool: EaselTool, start: EaselPoint, before: EaselDocument, id: String)
    }

    private var drag: Drag?

    private func snapCandidates(excluding ids: Set<String>) -> [EaselRect] {
        let v = visibleRect_.insetBy(-400 / zoom)
        return document.blocks.filter { !ids.contains($0.id) && $0.bounds.intersects(v) }.map(\.bounds)
    }

    private var snapDistance: Double { EaselMetrics.snapDistance / zoom }

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil { endEditing() }
        window?.makeFirstResponder(self)
        let vp = convert(event.locationInWindow, from: nil)
        let p = plane(vp)
        if tool == .hand || spaceHeld || event.buttonNumber == 2 {
            drag = .pan(last: vp)
            NSCursor.closedHand.set()
            return
        }
        switch tool {
        case .select, .hand:
            if let h = handle(at: vp), let box = selectionBox() {
                let ids = selection
                switch h {
                case .rotate: drag = .rotate(start: p, before: document, center: box.rect.center, ids: ids)
                case .lineStart, .lineEnd: if let id = box.single?.id { drag = .lineEnd(start: h == .lineStart, before: document, id: id) }
                case .resize: drag = .resize(handle: h, start: p, before: document, box: box, ids: ids, others: snapCandidates(excluding: ids))
                }
                return
            }
            if let b = document.hit(p, slop: 4 / zoom) {
                if event.clickCount == 2 { return doubleClick(b) }
                let ids = document.expandingGroups([b.id])
                if event.modifierFlags.contains(.shift) {
                    selection = selection.isSuperset(of: ids) ? selection.subtracting(ids) : selection.union(ids)
                    if !selection.contains(b.id) { return }
                } else if !selection.contains(b.id) {
                    selection = ids
                }
                beginMove(at: p, duplicate: event.modifierFlags.contains(.option))
                return
            }
            if !event.modifierFlags.contains(.shift) { selection = [] }
            drag = .marquee(start: p, initial: selection)
        case .text:
            beginNewText(at: p)
        case .rectangle, .ellipse, .arrow, .line:
            let before = document
            var d = before
            let b: EaselBlock
            switch tool {
            case .rectangle, .ellipse:
                let shape = EaselShape(tool == .rectangle ? .rectangle : .ellipse, fill: EaselEditor.lastFill)
                b = EaselBlock(frame: EaselRect(x: p.x, y: p.y, width: 0, height: 0), content: .shape(shape))
            default:
                b = EaselBlock(frame: EaselRect(x: p.x, y: p.y, width: 0, height: 0),
                               content: .line(EaselLine(from: p, to: p, endHead: tool == .arrow, color: EaselEditor.lastLineColor)))
            }
            d.add(b)
            editor?.setLive(d)
            selection = [b.id]
            drag = .create(tool: tool, start: p, before: before, id: b.id)
        }
    }

    private func beginMove(at p: EaselPoint, duplicate: Bool) {
        guard let editor else { return }
        let before = document
        var ids = selection
        var name = "Move"
        if duplicate {
            // ⌥-drag: copies move, the originals stay.
            var d = before
            ids = Set(d.duplicate(selection, offset: 0))
            for id in ids { startOfCopies[id] = d.block(id) }
            editor.setLive(d)
            selection = ids
            name = "Duplicate"
        }
        let box = document.blocks.filter { ids.contains($0.id) }.map(\.bounds).reduce(nil as EaselRect?) { $0?.union($1) ?? $1 } ?? EaselRect(x: p.x, y: p.y, width: 0, height: 0)
        drag = .move(start: p, before: before, ids: ids, box: box, others: snapCandidates(excluding: ids), name: name)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let editor else { return }
        let vp = convert(event.locationInWindow, from: nil)
        let p = plane(vp)
        let shift = event.modifierFlags.contains(.shift)
        let noSnap = event.modifierFlags.contains(.command)
        switch drag {
        case .pan(let last):
            pan(dx: Double(vp.x - last.x), dy: Double(vp.y - last.y))
            self.drag = .pan(last: vp)
        case .move(let start, let before, let ids, let box, let others, _):
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            var g: [EaselSnapping.Guide] = []
            if !noSnap {
                let s = EaselSnapping.snap(box.offsetBy(dx: dx, dy: dy), to: others, distance: snapDistance)
                dx += s.dx
                dy += s.dy
                g = s.guides
            }
            let d = moved(before: before, current: document, ids: ids, dx: dx, dy: dy)
            guides = g
            if !g.isEmpty { lastGuidesDuringDrag = g }
            editor.setLive(d)
        case .resize(let h, _, let before, let box, let ids, let others):
            guard case .resize(let hx, let hy) = h else { return }
            var r = box.rect
            let q = EaselGeometry.rotate(p, about: box.rect.center, by: -box.rotation)
            let minSide = EaselMetrics.minimumSide
            if hx == -1 { let x = min(q.x, r.maxX - minSide); r = EaselRect(x: x, y: r.y, width: r.maxX - x, height: r.height) }
            if hx == 1 { r.width = max(minSide, q.x - r.minX) }
            if hy == -1 { let y = min(q.y, r.maxY - minSide); r = EaselRect(x: r.x, y: y, width: r.width, height: r.maxY - y) }
            if hy == 1 { r.height = max(minSide, q.y - r.minY) }
            // Pictures keep their shape at a corner (⇧ frees them); others keep theirs with ⇧.
            let keepsShape: Bool = {
                guard hx != 0, hy != 0 else { return false }
                if let b = box.single, case .image = b.content { return !shift }
                if let b = box.single, case .capture = b.content { return !shift }
                return shift
            }()
            if keepsShape {
                let aspect = box.rect.height / max(0.001, box.rect.width)
                let w = max(r.width, r.height / aspect), h2 = w * aspect
                r = EaselRect(x: hx == -1 ? box.rect.maxX - w : box.rect.minX, y: hy == -1 ? box.rect.maxY - h2 : box.rect.minY, width: w, height: h2)
            }
            var g: [EaselSnapping.Guide] = []
            if box.rotation == 0, !noSnap, !keepsShape {
                let s = EaselSnapping.snapEdges(r, left: hx == -1, right: hx == 1, top: hy == -1, bottom: hy == 1, to: others, distance: snapDistance)
                r = s.box
                g = s.guides
            }
            if box.rotation != 0 {
                // The opposite side stays put on screen: the new frame's centre, turned about the old one.
                let c = EaselGeometry.rotate(r.center, about: box.rect.center, by: box.rotation)
                r = r.offsetBy(dx: c.x - r.midX, dy: c.y - r.midY)
            }
            var d = before
            if let b = box.single {
                d.update(b.id) { x in
                    x.frame = r
                    if case .text(let t) = x.content {
                        x.frame.height = max(r.height, EaselTextRender.height(t, width: r.width, look: look))
                    }
                }
            } else {
                d.resize(ids, from: box.rect, to: r)
            }
            guides = g
            if !g.isEmpty { lastGuidesDuringDrag = g }
            editor.setLive(d)
        case .rotate(let start, let before, let c, let ids):
            var a = atan2(p.y - c.y, p.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            if shift { a = (a / (.pi / 12)).rounded() * (.pi / 12) }
            var d = before
            d.rotate(ids, by: a, about: c)
            editor.setLive(d)
        case .lineEnd(let isStart, let before, let id):
            guard var l = before.block(id)?.line else { return }
            var q = p
            let other = isStart ? l.to : l.from
            if shift {
                let ang = (atan2(q.y - other.y, q.x - other.x) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(q.x - other.x, q.y - other.y)
                q = EaselPoint(other.x + cos(ang) * len, other.y + sin(ang) * len)
            }
            if isStart { l.from = q } else { l.to = q }
            var d = before
            d.update(id) { $0.setLine(l) }
            editor.setLive(d)
        case .marquee(let start, let initial):
            let r = EaselRect(spanning: start, p)
            marquee = r
            let hit = Set(document.blocks(in: r).map(\.id))
            selection = initial.union(document.expandingGroups(hit))
            selectionChanged()
        case .create(let t, let start, let before, let id):
            var d = before
            guard var b = document.block(id) else { return }
            if t == .rectangle || t == .ellipse {
                var q = p
                if shift { let s = max(abs(p.x - start.x), abs(p.y - start.y)); q = EaselPoint(start.x + (p.x < start.x ? -s : s), start.y + (p.y < start.y ? -s : s)) }
                b.frame = EaselRect(spanning: start, q)
            } else if var l = b.line {
                var q = p
                if shift {
                    let ang = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(p.x - start.x, p.y - start.y)
                    q = EaselPoint(start.x + cos(ang) * len, start.y + sin(ang) * len)
                }
                l.to = q
                b.setLine(l)
            }
            d.blocks.append(b)
            editor.setLive(d)
        }
    }

    /// `before` with `ids` moved by (dx, dy) — copies made by ⌥-drag already in `current` are taken from there.
    private func moved(before: EaselDocument, current: EaselDocument, ids: Set<String>, dx: Double, dy: Double) -> EaselDocument {
        var d = before
        let missing = ids.filter { before.block($0) == nil }
        if !missing.isEmpty {
            // ⌥-drag copies: as they were made (at the originals' place), then moved.
            for id in missing { if let o = startOfCopies[id] ?? current.block(id) { d.blocks.append(o) } }
        }
        d.move(ids, dx: dx, dy: dy)
        return d
    }

    /// ⌥-drag: where each copy started.
    private var startOfCopies: [String: EaselBlock] = [:]

    override func mouseUp(with event: NSEvent) {
        guard let drag, let editor else { return }
        self.drag = nil
        guides = []
        marquee = nil
        startOfCopies = [:]
        switch drag {
        case .pan:
            NSCursor.arrow.set()
        case .move(let start, let before, _, _, _, let name):
            let p = plane(event)
            if hypot(p.x - start.x, p.y - start.y) * zoom < 1, name == "Move" {
                editor.setLive(before)
            } else {
                editor.endLive(from: before, name: name)
            }
            lastGuides = lastGuidesDuringDrag
        case .resize(_, _, let before, _, _, _):
            editor.endLive(from: before, name: "Resize")
            lastGuides = lastGuidesDuringDrag
        case .rotate(_, let before, _, _):
            editor.endLive(from: before, name: "Rotate")
        case .lineEnd(_, let before, _):
            editor.endLive(from: before, name: "Move End")
        case .marquee:
            break
        case .create(let t, let start, let before, let id):
            let p = plane(event)
            var d = document
            // A click (no drag): one of its usual size there.
            if hypot(p.x - start.x, p.y - start.y) * zoom < 4 {
                d.update(id) { b in
                    if var l = b.line {
                        l.to = EaselPoint(start.x + 160, start.y)
                        b.setLine(l)
                    } else {
                        b.frame = EaselRect(x: start.x - 80, y: start.y - 55, width: 160, height: 110)
                    }
                }
                editor.setLive(d)
            }
            editor.endLive(from: before, name: t == .rectangle ? "Add Rectangle" : t == .ellipse ? "Add Ellipse" : t == .arrow ? "Add Arrow" : "Add Line")
            selection = [id]
            tool = .select
        }
        lastGuidesDuringDrag = []
        selectionChanged()
    }

    private var lastGuidesDuringDrag: [EaselSnapping.Guide] = []

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = plane(event)
        if let b = document.hit(p, slop: 4 / zoom), !selection.contains(b.id) { selection = document.expandingGroups([b.id]) }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        drag = .pan(last: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    private func doubleClick(_ b: EaselBlock) {
        switch b.content {
        case .text: beginEditing(b.id)
        case .link(let l): if let u = URL(string: l.url) { editor?.controller?.openFromEasel(u) }
        case .capture(let c):
            // P19b: a live Capture is the real page for a while; a static one opens its page.
            if c.live != nil, let editor { return EaselInteraction.begin(editor, blockID: b.id) }
            if let u = c.url.flatMap(URL.init(string:)) { editor?.controller?.openFromEasel(u) }
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                let f = exp(Double(event.scrollingDeltaY) * 0.01)
                setZoom(zoom * f, about: convert(event.locationInWindow, from: nil))
            } else {
                pan(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY))
            }
        } else {
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                setZoom(zoom * (event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1), about: convert(event.locationInWindow, from: nil))
            } else {
                let dx = event.modifierFlags.contains(.shift) ? Double(event.scrollingDeltaY) : Double(event.scrollingDeltaX)
                let dy = event.modifierFlags.contains(.shift) ? 0 : Double(event.scrollingDeltaY)
                pan(dx: dx * 12, dy: dy * 12)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + Double(event.magnification)), about: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(zoom - 1) < 0.01 { zoomToFit(animated: true) } else { setZoom(1, about: convert(event.locationInWindow, from: nil), animated: true) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .hand ? .openHand : tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }

    // MARK: Text

    var isEditingText: Bool { textEditor != nil }
    var editingBlockID: String? { editingID }

    private func beginNewText(at p: EaselPoint) {
        guard let editor else { return }
        let before = document
        var d = before
        let t = EaselText(font: EaselEditor.lastFont, size: EaselEditor.lastTextSize)
        let b = EaselBlock(frame: EaselRect(x: p.x, y: p.y - EaselEditor.lastTextSize, width: 280, height: EaselTextRender.height(t, width: 280, look: look)), content: .text(t))
        d.add(b)
        editor.setLive(d)
        selection = [b.id]
        tool = .select
        beginEditing(b.id, before: before)
    }

    /// The text block `id` in place: a text view over it (unturned, at the zoom), the layer's text hidden meanwhile.
    func beginEditing(_ id: String, before: EaselDocument? = nil) {
        guard let b = document.block(id), case .text(let t) = b.content, let host = editor?.view else { return }
        if textEditor != nil { endEditing() }
        editingID = id
        editingBefore = before ?? document
        let tv = EaselTextView(frame: .zero)
        tv.owner = self
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: EaselTextRender.textInset * zoom, height: EaselTextRender.textInset * zoom)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.focusRingType = .none
        tv.insertionPointColor = look.accent
        tv.linkTextAttributes = [.foregroundColor: look.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        tv.textStorage?.setAttributedString(EaselTextRender.attributed(t, look: look, scale: CGFloat(zoom)))
        tv.typingAttributes = tv.textStorage?.length ?? 0 > 0
            ? tv.textStorage!.attributes(at: max(0, tv.textStorage!.length - 1), effectiveRange: nil)
            : EaselTextRender.typingAttributes(t, look: look, scale: CGFloat(zoom))
        tv.delegate = self
        tv.setAccessibilityIdentifier("easel.text.editor")
        host.addSubview(tv, positioned: .above, relativeTo: self)
        textEditor = tv
        blockLayers[id]?.hidesText = true
        updateTextEditorFrame()
        selectionChanged()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        if (tv.textStorage?.length ?? 0) == 0 { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    private func updateTextEditorFrame() {
        guard let tv = textEditor, let id = editingID, let b = document.block(id) else { return }
        let r = viewRect(b.frame)
        tv.frame = NSRect(x: r.minX, y: r.minY, width: max(20, r.width), height: max(r.height, tv.frame.height))
    }

    /// What's typed, as the block's runs; its height follows.
    private func editedText() -> EaselText? {
        guard let tv = textEditor, let id = editingID, case .text(var t)? = document.block(id)?.content else { return nil }
        // Unscaled for the document: NoteText reads only the line kinds and marks, never fonts.
        t.text = NoteText.document(tv.attributedString(), trailing: .paragraph)
        return t
    }

    func textDidChange(_ notification: Notification) {
        guard let id = editingID, let t = editedText(), let editor else { return }
        var d = document
        d.update(id) { b in
            b.content = .text(t)
            b.frame.height = EaselTextRender.height(t, width: b.frame.width, look: look)
        }
        editor.setLive(d)
        updateTextEditorFrame()
    }

    /// Typing ends (Esc, a click elsewhere, the tool changing): one undo step, or none for an empty new block.
    func endEditing() {
        guard let tv = textEditor, let id = editingID, let editor else { return }
        let before = editingBefore ?? document
        let t = editedText()
        textEditor = nil
        editingID = nil
        editingBefore = nil
        tv.delegate = nil
        if window?.firstResponder === tv { window?.makeFirstResponder(self) }
        tv.removeFromSuperview()
        blockLayers[id]?.hidesText = false
        let empty = t?.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if empty {
            if before.block(id) == nil {
                editor.setLive(before)
            } else {
                var d = document
                d.remove([id])
                editor.setLive(d)
                editor.endLive(from: before, name: "Delete")
                selection = []
            }
        } else {
            editor.endLive(from: before, name: before.block(id) == nil ? "Add Text" : "Edit Text")
            selection = [id]
        }
        selectionChanged()
    }

    // MARK: Keys

    func claims(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods.contains(.control) { return false }   // ⌃⇧E (New Easel) and the rest stay the browser's
        if mods.contains(.command) {
            return ["z", "d", "g", "a", "c", "v", "x", "=", "+", "-", "0", "]", "[", "1", "2", "r"].contains(chars)
        }
        // Esc only when there's something to let go of.
        if e.keyCode == 53 { return !selection.isEmpty || tool != .select }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.contains(.command), !mods.contains(.control) else { return super.performKeyEquivalent(with: event) }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = mods.contains(.shift)
        switch chars {
        case "z": shift ? editor?.redo() : editor?.undo()
        case "d": editor?.duplicateSelection()
        case "g": shift ? editor?.ungroupSelection() : editor?.groupSelection()
        case "a": selectAll(nil)
        case "c": editor?.copySelection()
        case "x": editor?.cutSelection()
        case "v": editor?.paste()
        case "=", "+": zoomStep(in: true)
        case "-": zoomStep(in: false)
        case "0": setZoom(1, about: nil, animated: true)
        case "1": zoomToFit(animated: true)
        case "2": zoomToFit(animated: true, selectionOnly: true)
        case "]": editor?.restack(shift ? "Bring to Front" : "Bring Forward")
        case "[": editor?.restack(shift ? "Send to Back" : "Send Backward")
        // Arc: ⌘R on an Easel refreshes all its Live Captures.
        case "r" where !shift: editor?.refreshLive()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let step = mods.contains(.shift) ? EaselMetrics.bigNudge : EaselMetrics.nudge
        switch Int(event.keyCode) {
        case 123: editor?.nudge(-step, 0)
        case 124: editor?.nudge(step, 0)
        case 125: editor?.nudge(0, step)
        case 126: editor?.nudge(0, -step)
        case 51, 117: editor?.deleteSelection()
        case 53:
            if tool != .select { tool = .select } else { selection = [] }
        case 36, 76:
            // Return edits the selected text.
            if selection.count == 1, let id = selection.first, case .text? = document.block(id)?.content { beginEditing(id) }
        case 49:
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.set() }
        default:
            guard mods.isEmpty || mods == .shift, let c = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }
            if mods == .shift, c == "1" || c == "!" { return zoomToFit(animated: true) }
            if mods == .shift, c == "2" || c == "@" { return zoomToFit(animated: true, selectionOnly: true) }
            if let t = EaselTool.allCases.first(where: { $0.key == c }) { tool = t; return }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            NSCursor.arrow.set()
        }
        super.keyUp(with: event)
    }

    // MARK: Edit menu

    @objc func undo(_ sender: Any?) { editor?.undo() }
    @objc func redo(_ sender: Any?) { editor?.redo() }
    @objc func delete(_ sender: Any?) { editor?.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { selection = Set(document.blocks.map(\.id)) }
    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) { editor?.cutSelection() }
    @objc func paste(_ sender: Any?) { editor?.paste() }
    @objc func duplicate(_ sender: Any?) { editor?.duplicateSelection() }
    @objc func group(_ sender: Any?) { editor?.groupSelection() }
    @objc func ungroup(_ sender: Any?) { editor?.ungroupSelection() }
    @objc func bringToFront(_ sender: Any?) { editor?.restack("Bring to Front") }
    @objc func bringForward(_ sender: Any?) { editor?.restack("Bring Forward") }
    @objc func sendBackward(_ sender: Any?) { editor?.restack("Send Backward") }
    @objc func sendToBack(_ sender: Any?) { editor?.restack("Send to Back") }
    @objc func editText(_ sender: Any?) { if let id = selection.first { beginEditing(id) } }

    @objc func refreshCapture(_ sender: Any?) { editor?.refreshLive(editor?.liveIDs()) }
    @objc func refreshAllCaptures(_ sender: Any?) { editor?.refreshLive() }
    @objc func toggleLiveUpdates(_ sender: Any?) {
        guard let editor else { return }
        let allLive = editor.liveIDs().allSatisfy { editor.document.liveSource($0)?.mode == .live }
        editor.setLiveMode(allLive ? .manual : .live)
    }
    @objc func detachCapture(_ sender: Any?) { editor?.detachLive() }
    @objc func interactCapture(_ sender: Any?) {
        guard let editor, let id = editor.liveIDs().first else { return }
        EaselInteraction.begin(editor, blockID: id)
    }

    // P19c: an Easel out of Airc (Easels/EaselSharing.swift).
    @objc func copyAsImage(_ sender: Any?) { editor?.copyImage() }
    @objc func exportEasel(_ sender: Any?) { editor?.export() }
    @objc func exportEaselImage(_ sender: Any?) { editor?.export(.image) }
    @objc func exportEaselWebPage(_ sender: Any?) { editor?.export(.webPage) }
    @objc func shareEaselLink(_ sender: Any?) { editor?.shareLink() }
    @objc func shareEaselPicture(_ sender: Any?) { editor?.sharePicture(from: nil) }

    @objc func openLink(_ sender: Any?) {
        guard let id = selection.first, let b = document.block(id) else { return }
        doubleClick(b)
    }

    @objc func copyLink(_ sender: Any?) {
        guard let id = selection.first, let u = linkURL(document.block(id)) else { return }
        let pb = EaselEditor.pasteboard()
        pb.clearContents()
        pb.setString(u, forType: .string)
    }

    private func linkURL(_ b: EaselBlock?) -> String? {
        switch b?.content {
        case .link(let l)?: l.url
        case .capture(let c)?: c.url
        case .image(let i)?: i.source
        default: nil
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let has = !selection.isEmpty
        switch item.action {
        case #selector(undo(_:)):
            item.title = editor?.history.undoName.map { "Undo \($0)" } ?? "Undo"
            return editor?.history.canUndo == true
        case #selector(redo(_:)):
            item.title = editor?.history.redoName.map { "Redo \($0)" } ?? "Redo"
            return editor?.history.canRedo == true
        case #selector(delete(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)),
             #selector(bringToFront(_:)), #selector(bringForward(_:)), #selector(sendBackward(_:)), #selector(sendToBack(_:)):
            return has
        case #selector(group(_:)): return selection.count >= 2
        case #selector(ungroup(_:)): return document.blocks.contains { selection.contains($0.id) && $0.group != nil }
        case #selector(selectAll(_:)): return !document.blocks.isEmpty
        case #selector(paste(_:)): return true
        case #selector(openLink(_:)), #selector(copyLink(_:)): return selection.count == 1 && linkURL(document.block(selection.first!)) != nil
        case #selector(refreshCapture(_:)), #selector(detachCapture(_:)): return editor?.liveIDs().isEmpty == false
        case #selector(interactCapture(_:)): return editor?.liveIDs().count == 1
        case #selector(refreshAllCaptures(_:)): return !document.liveBlocks.isEmpty
        case #selector(copyAsImage(_:)), #selector(exportEasel(_:)), #selector(exportEaselImage(_:)), #selector(exportEaselWebPage(_:)),
             #selector(shareEaselLink(_:)), #selector(shareEaselPicture(_:)):
            return !document.isEmpty
        case #selector(toggleLiveUpdates(_:)):
            guard let editor, !editor.liveIDs().isEmpty else { return false }
            item.state = editor.liveIDs().allSatisfy({ editor.document.liveSource($0)?.mode == .live }) ? .on : .off
            return true
        default: return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            m.addItem(i)
        }
        if selection.count == 1, let b = document.block(selection.first!) {
            if case .text = b.content { item("Edit Text", #selector(editText(_:)), "") }
            if case .capture(let c) = b.content, let live = c.live {
                // P19b: a live Capture's own items, its state first.
                let info = NSMenuItem(title: live.problem.map { "\($0) · \(EaselLivePolicy.age(live, now: Date()))" } ?? EaselLivePolicy.age(live, now: Date()),
                                      action: nil, keyEquivalent: "")
                info.isEnabled = false
                m.addItem(info)
                item("Refresh Capture", #selector(refreshCapture(_:)), "")
                item("Update Automatically", #selector(toggleLiveUpdates(_:)), "")
                item("Interact", #selector(interactCapture(_:)), "")
                item("Detach from Page", #selector(detachCapture(_:)), "")
                m.addItem(.separator())
            }
            if linkURL(b) != nil {
                item("Open Link", #selector(openLink(_:)), "")
                item("Copy Link", #selector(copyLink(_:)), "")
                m.addItem(.separator())
            }
        }
        if !document.liveBlocks.isEmpty, selection.count != 1 || editor?.liveIDs().isEmpty != false {
            item("Refresh All Captures", #selector(refreshAllCaptures(_:)), "r")
            m.addItem(.separator())
        }
        item("Cut", #selector(cut(_:)), "x")
        item("Copy", #selector(copy(_:)), "c")
        item("Paste", #selector(paste(_:)), "v")
        item("Duplicate", #selector(duplicate(_:)), "d")
        item("Delete", #selector(delete(_:)), "\u{8}", [])
        m.addItem(.separator())
        item("Group", #selector(group(_:)), "g")
        item("Ungroup", #selector(ungroup(_:)), "g", [.command, .shift])
        m.addItem(.separator())
        item("Bring to Front", #selector(bringToFront(_:)), "]", [.command, .shift])
        item("Bring Forward", #selector(bringForward(_:)), "]")
        item("Send Backward", #selector(sendBackward(_:)), "[")
        item("Send to Back", #selector(sendToBack(_:)), "[", [.command, .shift])
        m.addItem(.separator())
        item(selection.isEmpty ? "Copy Easel as Image" : "Copy as Image", #selector(copyAsImage(_:)), "")
        item("Export as Image…", #selector(exportEaselImage(_:)), "")
        item("Export as Web Page…", #selector(exportEaselWebPage(_:)), "")
        item("Share Link…", #selector(shareEaselLink(_:)), "")
        return m
    }

    // MARK: Drops (pictures, files, links from pages and other apps; blocks from another Easel)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let editor else { return false }
        let p = plane(convert(sender.draggingLocation, from: nil))
        return EaselDrops.drop(sender.draggingPasteboard, on: editor, at: p)
    }

    // MARK: Measuring (the perf check)

    /// Pans by `step` view points a frame for `frames` display frames and reports the frame intervals the display link
    /// saw (seconds). Driven by the window's display link, so a frame the main thread or Core Animation couldn't make
    /// in time shows as a long interval.
    func measurePan(frames: Int, step: Double, _ done: @escaping ([Double]) -> Void) {
        var intervals: [Double] = []
        var last: CFTimeInterval = 0
        var n = 0
        let proxy = DisplayLinkProxy { [weak self] link in
            guard let self else { return }
            let now = link.timestamp
            if last > 0 { intervals.append(now - last) }
            last = now
            // Back and forth, so the content stays in view.
            let dir: Double = (n / 60) % 2 == 0 ? 1 : -1
            self.pan(dx: step * dir, dy: step * 0.5 * dir)
            n += 1
            if n > frames {
                link.invalidate()
                done(intervals)
            }
        }
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        proxy.link = link
        link.add(to: .main, forMode: .common)
    }
}

/// A display link's target that forwards to a closure (CADisplayLink retains its target).
final class DisplayLinkProxy: NSObject {
    let body: (CADisplayLink) -> Void
    weak var link: CADisplayLink?
    init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
    @objc func tick(_ link: CADisplayLink) { body(link) }
}

/// The text view a text block is edited in: Esc ends it; ⌘B ⌘I ⌘U mark the selection (the note's marks).
final class EaselTextView: NSTextView, EaselKeyOwner {
    weak var owner: EaselCanvasView?

    func claims(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
        return mods == .command && ["b", "i", "u", "a", "z"].contains(c) || mods == [.command, .shift] && ["z", "x"].contains(c)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command, let mark: NoteMarks = ["b": .bold, "i": .italic, "u": .underline][c] { toggle(mark); return true }
        if mods == [.command, .shift], c == "x" { toggle(.strikethrough); return true }
        if mods == .command, c == "a" { selectAll(nil); return true }
        if mods == .command, c == "z" { undoManager?.undo(); return true }
        if mods == [.command, .shift], c == "z" { undoManager?.redo(); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Bold, italic…: on the selection (all of it has the mark: it goes), redrawn from the marks.
    func toggle(_ mark: NoteMarks) {
        guard let storage = textStorage else { return }
        let r = selectedRange()
        guard r.length > 0 else {
            var marks = NoteMarks.of(typingAttributes[.noteMarks])
            if marks.contains(mark) { marks.remove(mark) } else { marks.insert(mark) }
            typingAttributes[.noteMarks] = marks.isEmpty ? nil : NSNumber(value: marks.rawValue)
            restyleTyping(marks)
            return
        }
        var all = true
        storage.enumerateAttribute(.noteMarks, in: r) { v, _, _ in if !NoteMarks.of(v).contains(mark) { all = false } }
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.noteMarks, in: r) { v, sub, _ in
            var m = NoteMarks.of(v)
            if all { m.remove(mark) } else { m.insert(mark) }
            storage.addAttribute(.noteMarks, value: NSNumber(value: m.rawValue), range: sub)
            restyle(storage, sub, m)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(r)
    }

    private func restyle(_ storage: NSTextStorage, _ r: NSRange, _ m: NoteMarks) {
        storage.enumerateAttribute(.font, in: r) { v, sub, _ in
            guard let f = v as? NSFont else { return }
            var out = f
            let fm = NSFontManager.shared
            out = m.contains(.bold) ? fm.convert(out, toHaveTrait: .boldFontMask) : fm.convert(out, toNotHaveTrait: .boldFontMask)
            out = m.contains(.italic) ? fm.convert(out, toHaveTrait: .italicFontMask) : fm.convert(out, toNotHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: out, range: sub)
        }
        if m.contains(.underline) { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) } else { storage.removeAttribute(.underlineStyle, range: r) }
        if m.contains(.strikethrough) { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) } else { storage.removeAttribute(.strikethroughStyle, range: r) }
    }

    private func restyleTyping(_ m: NoteMarks) {
        if let f = typingAttributes[.font] as? NSFont {
            let fm = NSFontManager.shared
            var out = m.contains(.bold) ? fm.convert(f, toHaveTrait: .boldFontMask) : fm.convert(f, toNotHaveTrait: .boldFontMask)
            out = m.contains(.italic) ? fm.convert(out, toHaveTrait: .italicFontMask) : fm.convert(out, toNotHaveTrait: .italicFontMask)
            typingAttributes[.font] = out
        }
    }

    override func cancelOperation(_ sender: Any?) { owner?.endEditing() }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r, owner?.textEditor === self { DispatchQueue.main.async { [weak self] in if let self, self.owner?.textEditor === self, self.window?.firstResponder !== self { self.owner?.endEditing() } } }
        return r
    }
}

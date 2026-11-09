// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// What a window gives Capture (CB-5): where the page card is, the pages on it, and how it says things.
protocol CaptureHost: AnyObject {
    var captureWindow: NSWindow { get }
    /// The view the overlay goes into (the window's root), and the page card's frame in it. The overlay covers only the
    /// card, never the sidebar.
    var captureRoot: NSView { get }
    var captureCardFrame: NSRect { get }
    /// The pages on the card now, bottom first: the shown tab, or a split's panes, with Peek's page on top.
    var capturePages: [EngineTab] { get }
    var capturePalette: Palette { get }
    /// A private window: Capture works there too, but counts and keeps nothing.
    var captureIsPrivate: Bool { get }
    func captureToast(_ text: String)
    /// Views Airc draws itself on the card (a note's editor, alone or in a split's pane), pictured from their drawing.
    var captureViews: [NSView] { get }
    /// The page Capture Full Page takes: Peek's, else the focused pane's or the shown tab's.
    var captureFocusedPage: EngineTab? { get }
}

extension CaptureHost {
    var captureViews: [NSView] { [] }
    var captureFocusedPage: EngineTab? { capturePages.last }
}

/// Arc's Capture (⇧⌘2, View › Capture…, the Command Bar's "Capture…"): the page card dims, a drag selects a rectangle
/// (or ⌘ picks the element under the pointer, or Space the whole visible page), Return confirms, and the bar under it
/// copies, saves or shares the PNG. Arc's Capture Full Page (F, the bar's Full Page, View › Capture Full Page) takes the
/// focused page's whole length instead (FullPageCapture.swift), and Arc's Capture in Portrait Mode (P, the bar's
/// Portrait, the Command Bar) frames the page on a colour or the desktop picture (PortraitCapture.swift); each shows
/// before Copy, Save and Share, which all take that one picture.
///
/// The pixels are the engines' own pictures of the pages as composited (Chromium's surface copy, WebKit's snapshot),
/// taken once when Capture starts: what the overlay shows is exactly what the PNG holds, at the window's backing scale.
/// Never a screen capture (no permission prompt, nothing of other apps or of the sidebar). A protected (DRM) video
/// comes out as the engine pictures it, usually black.
final class CaptureSession: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    enum Phase { case selecting, confirmed, capturing }

    /// One page under the overlay: its frame in the overlay's points, and its picture once the engine sends it.
    struct Shot {
        let tab: EngineTab
        let frame: CGRect
        var image: CGImage?
    }

    /// A view Airc draws itself (a note's editor): its frame in the overlay's points and its picture.
    struct ViewShot {
        let frame: CGRect
        let image: CGImage?
    }

    // MARK: Where things go (scripted runs use their scratch folder and their own pasteboard)

    static var downloadsDirectory: () -> URL = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    static var pasteboard: () -> NSPasteboard = { .general }
    /// Shows the share sheet for `items` (a PNG file) from `anchor`.
    static var presentShare: (NSSharingServicePicker, _ items: [Any], _ anchor: NSView) -> Void = { picker, _, anchor in
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    /// `feature.used` `capture`; never from a private window.
    static var recordUse: (TelemetryFeature.CaptureAction) -> Void = { Telemetry.shared.record(.featureUsed(.capture($0))) }
    /// How long a page's picture may take before Capture gives up on that page.
    static let pictureTimeout: TimeInterval = 4

    private static var sessions: [ObjectIdentifier: CaptureSession] = [:]
    static func active(in window: NSWindow?) -> CaptureSession? { window.flatMap { sessions[ObjectIdentifier($0)] } }

    /// ⇧⌘2: starts Capture in `host`'s window, or ends the one running there. `fullPage`: Capture Full Page;
    /// `portrait`: Capture in Portrait Mode (PortraitCapture.swift), of the full page when both. Either goes on in a
    /// running Capture rather than ending it.
    static func toggle(_ host: CaptureHost, fullPage: Bool = false, portrait: Bool = false) {
        if let s = active(in: host.captureWindow) {
            if portrait { return s.capturePortrait(fullPage: fullPage) }
            return fullPage ? s.captureFullPage() : s.cancel()
        }
        let w = host.captureWindow
        host.captureRoot.layoutSubtreeIfNeeded()
        let tabs = host.capturePages.filter { !$0.isClosed && $0.view.window === w && !$0.view.isHiddenOrHasHiddenAncestor }
        let views = host.captureViews.filter { $0.window === w && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width >= 1 && $0.bounds.height >= 1 }
        guard !tabs.isEmpty || !views.isEmpty, host.captureCardFrame.width >= 40, host.captureCardFrame.height >= 40 else {
            host.captureToast("There's no page to capture")
            return
        }
        let s = CaptureSession(host: host, tabs: tabs)
        sessions[ObjectIdentifier(w)] = s
        s.wantsFullPage = fullPage && !portrait
        if portrait { s.wantsPortrait = (fullPage, false) }
        s.begin(tabs, views: views)
    }

    private(set) weak var host: CaptureHost?
    private weak var window: NSWindow?
    let overlay = CaptureOverlayView()
    private(set) var phase = Phase.selecting
    private(set) var shots: [Shot] = []
    /// The views Airc draws itself under the overlay (below the pages: a split's note pane, a note in the card).
    private(set) var viewShots: [ViewShot] = []
    /// Every page's picture has come (or timed out).
    private(set) var picturesReady = false
    /// The pixels per point of the output: the window's backing scale.
    private(set) var scale: CGFloat = 2
    /// The confirmed PNG's pixels, and their pixels per point (a full page's can be fewer than the window's).
    private(set) var result: CGImage?
    private(set) var resultScale: CGFloat = 2
    /// Capture Full Page's picture while it's the result (shown over the card, scaled to fit).
    private(set) var fullPagePicture: FullPageCapture.Picture?
    /// The page Capture Full Page took.
    private weak var fullPageTab: EngineTab?
    /// Capture Full Page was asked for before the pages' pictures came: it starts when they have.
    private var wantsFullPage = false
    /// Capture in Portrait Mode, the same (of the full page; quick: copied at once in the remembered style).
    private var wantsPortrait: (fullPage: Bool, quick: Bool)?
    /// The portrait on screen: what it frames and how (PortraitCapture.swift).
    private(set) var portrait: Portrait?
    struct Portrait {
        let content: CGImage
        let contentScale: CGFloat
        let website: NSColor
        weak var tab: EngineTab?
        var style: PortraitStyle
        /// The desktop picture, read once it's picked.
        var wallpaper: CGImage?
        var layout: PortraitCapture.Layout?
    }
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private weak var responderBefore: NSResponder?
    private var ended = false
    private var shareFile: URL?

    private init(host: CaptureHost, tabs: [EngineTab]) {
        self.host = host
        window = host.captureWindow
        super.init()
    }

    private func begin(_ tabs: [EngineTab], views: [NSView]) {
        guard let host, let window else { return }
        scale = window.backingScaleFactor
        #if AIRC_TESTING
        if let s = Self.scaleOverride { scale = s }
        #endif
        resultScale = scale
        overlay.session = self
        overlay.palette = host.capturePalette
        overlay.frame = host.captureCardFrame
        // Airc's own views are pictured from their drawing, before the overlay covers them.
        let pictures = views.map { Self.picture(of: $0) }
        host.captureRoot.addSubview(overlay)
        viewShots = zip(views, pictures).map { v, image in
            ViewShot(frame: v.convert(v.bounds, to: overlay).intersection(overlay.bounds), image: image)
        }
        shots = tabs.map { Shot(tab: $0, frame: $0.view.convert($0.view.bounds, to: overlay).intersection(overlay.bounds), image: nil) }
        responderBefore = window.firstResponder
        window.makeFirstResponder(overlay)
        overlay.appear()
        watch(window)
        var left = shots.count
        if shots.isEmpty { picturesArrived() }
        for i in shots.indices {
            Self.picture(of: shots[i].tab, while: { [weak self] in self?.ended == false }) { [weak self] image in
                guard let self, !self.ended else { return }
                self.shots[i].image = image
                left -= 1
                if left == 0 { self.picturesArrived() }
            }
        }
    }

    private func picturesArrived() {
        picturesReady = true
        guard shots.contains(where: { $0.image != nil }) || viewShots.contains(where: { $0.image != nil }) else {
            finish()
            host?.captureToast("This page can't be captured")
            return
        }
        overlay.frozen = render(selection: overlay.bounds, scale: window?.backingScaleFactor ?? scale)
        overlay.update()
        if let p = wantsPortrait { capturePortrait(fullPage: p.fullPage, quick: p.quick) }
        else if wantsFullPage { captureFullPage() }
    }

    #if AIRC_TESTING
    /// Exercise the engine's transient no-surface reply without devices, screen capture or focus changes.
    static var pictureRequest: ((EngineTab, @escaping (NSImage?) -> Void) -> Void)?
    /// The output's pixels per point instead of the window's (1× on a Retina display).
    static var scaleOverride: CGFloat?
    #endif

    /// A view of Airc's own as it's drawn, at its window's backing scale.
    static func picture(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Chromium can return nil before the first compositor surface exists (including a background private window).
    /// Loading/title callbacks do not promise a surface. Retry empty replies within one total deadline, never after
    /// cancellation, closing or navigation; a late reply cannot finish a newer session.
    static func picture(of tab: EngineTab, while isCurrent: @escaping () -> Bool = { true }, _ done: @escaping (CGImage?) -> Void) {
        var answered = false
        let deadline = ProcessInfo.processInfo.systemUptime + pictureTimeout
        let url = tab.url
        func finish(_ image: CGImage?) {
            guard !answered else { return }
            answered = true
            done(image)
        }
        func request() {
            guard !answered else { return }
            guard isCurrent(), !tab.isClosed, tab.url == url,
                  ProcessInfo.processInfo.systemUptime < deadline else { return finish(nil) }
            let reply: (NSImage?) -> Void = { image in
                let pixels = image.flatMap(Self.pixels)
                DispatchQueue.main.async {
                    guard !answered else { return }
                    guard isCurrent(), !tab.isClosed, tab.url == url else { return finish(nil) }
                    if let pixels { finish(pixels) }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { request() } }
                }
            }
            #if AIRC_TESTING
            if let pictureRequest { pictureRequest(tab, reply); return }
            #endif
            tab.snapshot(completion: reply)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pictureTimeout) { finish(nil) }
        request()
    }

    /// The largest bitmap in `image` (a WebKit snapshot is sized in points with a 2× bitmap; Chromium's in pixels).
    static func pixels(_ image: NSImage) -> CGImage? {
        let reps = image.representations.sorted { $0.pixelsWide * $0.pixelsHigh > $1.pixelsWide * $1.pixelsHigh }
        for rep in reps {
            if let b = rep as? NSBitmapImageRep, let cg = b.cgImage { return cg }
            if let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        }
        var r = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    /// Everything under the overlay, bottom first: Airc's own views, then the pages (Peek's on top).
    var pages: [CaptureGeometry.Page] {
        viewShots.map { CaptureGeometry.Page(frame: $0.frame, pixelSize: CGSize(width: $0.image?.width ?? 0, height: $0.image?.height ?? 0)) }
            + shots.map { CaptureGeometry.Page(frame: $0.frame, pixelSize: CGSize(width: $0.image?.width ?? 0, height: $0.image?.height ?? 0)) }
    }
    private var images: [CGImage?] { viewShots.map(\.image) + shots.map(\.image) }

    /// The whole visible page (Space): the pages' union.
    var fullPage: CGRect? {
        CaptureGeometry.fullPage((viewShots.map(\.frame) + shots.map(\.frame)).map { CaptureGeometry.Page(frame: $0, pixelSize: .zero) }, in: overlay.bounds)
    }

    /// The pixels of `selection` (overlay points) at the output's scale; nil when no picture is under it.
    func render(selection: CGRect, scale: CGFloat? = nil) -> CGImage? {
        guard let plan = CaptureGeometry.plan(selection: selection, pages: pages, scale: scale ?? self.scale) else { return nil }
        return Self.render(plan, images: images)
    }

    static func render(_ plan: CaptureGeometry.Plan, images: [CGImage?]) -> CGImage? {
        let w = Int(plan.pixelSize.width), h = Int(plan.pixelSize.height)
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        // The pictures' own colour space (the display's, as the engine composited it), so colours come out as shown.
        let space = images.lazy.compactMap { $0?.colorSpace }.first { $0.model == .rgb } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        for p in plan.pieces {
            guard p.page < images.count, let image = images[p.page], let part = image.cropping(to: p.source) else { continue }
            let d = p.destination
            ctx.draw(part, in: CGRect(x: d.minX, y: CGFloat(h) - d.maxY, width: d.width, height: d.height))
        }
        return ctx.makeImage()
    }

    /// The PNG, with its pixels per point as its resolution (144 dpi at 2×, 72 at 1×): an app that honours it (a Note,
    /// Preview, Pages) shows the Capture at its size on screen, not twice that.
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * max(1, scale)
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Ending

    /// Leaves without writing anything (Esc, ⇧⌘2 again, a click outside the card, the window resizing).
    func cancel() { finish() }

    private func finish() {
        guard !ended else { return }
        ended = true
        removeShareFile()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let window { Self.sessions[ObjectIdentifier(window)] = nil }
        overlay.disappear()
        if let window, window.firstResponder === overlay {
            if let r = responderBefore, (r as? NSView)?.window === window { window.makeFirstResponder(r) } else { window.makeFirstResponder(nil) }
        }
    }

    var isEnded: Bool { ended }

    private func watch(_ window: NSWindow) {
        // A click outside the card (the sidebar) ends it, and still does what it does.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if !self.overlay.bounds.contains(self.overlay.convert(e.locationInWindow, from: nil)) { self.cancel() }
            return e
        }) { monitors.append(m) }
        // The card moving under a frozen picture would show the wrong place.
        for name in [NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.cancel()
            })
        }
    }

    // MARK: Selecting

    /// Return (or the Capture button, or a double-click in the selection): the selection becomes the picture.
    func confirm() {
        guard phase == .selecting, picturesReady, let sel = overlay.selection,
              sel.width >= CaptureGeometry.minimumSide, sel.height >= CaptureGeometry.minimumSide else { return NSSound.beep() }
        guard let image = render(selection: sel) else { return NSSound.beep() }
        result = image
        resultScale = scale
        phase = .confirmed
        overlay.update()
    }

    /// Back to adjusting (a new drag after confirming, or after a full page).
    func reopen() {
        guard phase == .confirmed else { return }
        phase = .selecting
        result = nil
        resultScale = scale
        if fullPagePicture != nil || portrait != nil {
            fullPagePicture = nil
            fullPageTab = nil
            portrait = nil
            overlay.selection = nil
        }
    }

    /// Capture Full Page (F, the bar's Full Page, View › Capture Full Page): the focused page from its top to its foot,
    /// at the window's pixels per point (fewer for a very long page; cut beyond FullPageCapture's limits). The overlay
    /// says "Capture in Progress" meanwhile; Esc stops it.
    func captureFullPage(then framed: ((FullPageCapture.Picture, EngineTab) -> Void)? = nil) {
        guard !ended, phase != .capturing else { return }
        guard picturesReady else { wantsFullPage = true; return }
        wantsFullPage = false
        let focused = host?.captureFocusedPage
        guard let page = shots.first(where: { $0.tab === focused })?.tab ?? shots.last?.tab else {
            host?.captureToast("Full Page takes a web page")
            return NSSound.beep()
        }
        if phase == .confirmed { reopen() }
        phase = .capturing
        overlay.selection = nil
        overlay.update()
        FullPageCapture.capture(page, scale: scale, isCurrent: { [weak self] in self?.ended == false && self?.phase == .capturing }) { [weak self] outcome in
            guard let self, !self.ended, self.phase == .capturing else { return }
            switch outcome {
            case .success(let picture) where framed != nil:
                framed?(picture, page)
            case .success(let picture):
                self.fullPagePicture = picture
                self.fullPageTab = page
                self.result = picture.image
                self.resultScale = picture.scale
                self.phase = .confirmed
                self.overlay.update()
            case .failure(.cancelled):
                break
            case .failure:
                self.phase = .selecting
                self.overlay.update()
                self.host?.captureToast("Couldn't capture the full page")
            }
        }
    }

    /// Capture in Portrait Mode (P, the bar's Portrait, the Command Bar; ⌥ on Full Page for the full page): the
    /// visible page, or the whole page, framed (PortraitCapture.swift), shown with its controls before Copy, Save and
    /// Share. `quick` (⌥ on Portrait, as Arc's): copied at once in the remembered style.
    func capturePortrait(fullPage: Bool = false, quick: Bool = false) {
        guard !ended, phase != .capturing else { return }
        guard picturesReady else { wantsPortrait = (fullPage, quick); return }
        wantsPortrait = nil
        if phase == .confirmed { reopen() }
        let focused = host?.captureFocusedPage
        let tab = shots.first(where: { $0.tab === focused })?.tab ?? shots.last?.tab
        if fullPage {
            captureFullPage { [weak self] picture, page in
                self?.frame(picture.image, scale: picture.scale, tab: page, quick: quick)
            }
            return
        }
        // The whole visible page (every pane, Peek on top), as Space selects it.
        guard let content = render(selection: self.fullPage ?? overlay.bounds) else { return NSSound.beep() }
        frame(content, scale: scale, tab: tab, quick: quick)
    }

    private func frame(_ content: CGImage, scale contentScale: CGFloat, tab: EngineTab?, quick: Bool) {
        portrait = Portrait(content: content, contentScale: contentScale, website: PortraitCapture.websiteColor(theme: tab?.themeColor, picture: content),
                            tab: tab, style: PortraitStyle.saved, wallpaper: nil, layout: nil)
        fullPagePicture = nil
        fullPageTab = tab
        overlay.portraitControls.websiteColor = portrait!.website
        renderPortrait()
        if quick, phase == .confirmed { copyImage() }
    }

    /// The person changed the portrait's background or mark: remembered, and the picture made again.
    func portraitStyleChanged(_ style: PortraitStyle) {
        guard portrait != nil else { return }
        portrait?.style = style
        PortraitStyle.saved = style
        renderPortrait()
    }

    private func renderPortrait() {
        guard var p = portrait else { return }
        if p.style.background == .wallpaper, p.wallpaper == nil {
            let l = PortraitCapture.layout(page: CGSize(width: CGFloat(p.content.width) / p.contentScale, height: CGFloat(p.content.height) / p.contentScale))
            p.wallpaper = PortraitCapture.wallpaper(window?.screen, Int(max(l.canvas.width, l.canvas.height) * scale))
            if p.wallpaper == nil {
                host?.captureToast("Couldn't use the desktop picture")
                p.style.background = .color
            }
        }
        guard let made = PortraitCapture.render(content: p.content, contentScale: p.contentScale, scale: scale, style: p.style, website: p.website,
                                                wallpaper: p.wallpaper, watermark: PortraitCapture.watermarkImage) else {
            portrait = nil
            return NSSound.beep()
        }
        p.layout = made.layout
        portrait = p
        result = made.image
        resultScale = made.scale
        phase = .confirmed
        overlay.portraitControls.style = p.style
        overlay.update()
    }

    /// Space: the whole visible page, or back to the selection before it.
    private var beforeFullPage: CGRect??
    func toggleFullPage() {
        if phase == .confirmed { reopen() }
        if let previous = beforeFullPage, overlay.selection == fullPage {
            overlay.selection = previous
            beforeFullPage = nil
        } else {
            beforeFullPage = .some(overlay.selection)
            overlay.selection = fullPage
        }
        overlay.update()
    }

    /// The overlay's keys, before the page or the menus see them (KeyMonitor). False: not Capture's; it ends Capture
    /// first if it's a ⌘ shortcut, which then runs as usual (⌘T, ⌘W, ⌥⌘→ …).
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let typed = ShortcutCenter.typed(event), ShortcutCenter.shared.map.command(for: typed) == "view.capture" {
            cancel(); return true
        }
        // While the full page is being taken: Esc stops it, ⌘ shortcuts end Capture, nothing else.
        if phase == .capturing {
            if event.keyCode == 53 || mods.contains(.command) { cancel() }
            return !mods.contains(.command)
        }
        if mods.isEmpty, chars == "f" { captureFullPage(); return true }
        if mods.isEmpty, chars == "p" { capturePortrait(); return true }
        switch (event.keyCode, mods) {
        case (53, []): cancel()
        case (36, []), (76, []): phase == .confirmed ? copyImage() : confirm()
        case (49, []): toggleFullPage()
        case (123...126, _) where mods.isSubset(of: [.shift]): overlay.nudge(keyCode: event.keyCode, by: mods.contains(.shift) ? 10 : 1)
        default:
            if mods == .command, chars == "c" { copyImage(); return true }
            if mods == .command, chars == "s" { save(); return true }
            if mods == [.command, .shift], chars == "s" { saveAs(); return true }
            if mods.contains(.command) || mods.contains(.control) {
                cancel()
                return false
            }
            // Typing goes nowhere while Capture is up.
        }
        return true
    }

    // MARK: Copy, Save, Share

    /// The confirmed picture (confirming the selection first if Copy, Save or Share came straight from it).
    private func confirmedImage() -> CGImage? {
        if phase == .selecting { confirm() }
        return phase == .confirmed ? result : nil
    }

    private func used(_ action: TelemetryFeature.CaptureAction) {
        if host?.captureIsPrivate != true { Self.recordUse(action) }
    }

    func copyImage() {
        guard let image = confirmedImage(), let png = Self.png(image, scale: resultScale) else { return }
        let pb = Self.pasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // TIFF too, for older apps; made only if one asks for it.
        item.setDataProvider(TIFFProvider(image: image, scale: resultScale), forTypes: [.tiff])
        pb.writeObjects([item])
        used(.copy)
        let toast = host
        finish()
        toast?.captureToast("Copied Capture")
    }

    /// Save: a PNG in Downloads, "Capture example.com 2026-11-07 at 10.15.32.png". ⌥-click or ⇧⌘S asks where.
    func save() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true, NSApp.currentEvent?.type == .leftMouseUp { return saveAs() }
        guard let image = confirmedImage(), let png = Self.png(image, scale: resultScale) else { return }
        let dir = Self.downloadsDirectory()
        let name = CaptureFileName.make(url: siteURL, date: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        write(png, to: dir.appendingPathComponent(name), folderName: "Downloads")
    }

    func saveAs() {
        guard let image = confirmedImage(), let png = Self.png(image, scale: resultScale), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = CaptureFileName.make(url: siteURL, date: Date())
        panel.directoryURL = Self.downloadsDirectory()
        panel.canCreateDirectories = true
        overlay.isHidden = true
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard let self, !self.ended else { return }
            self.overlay.isHidden = false
            guard answer == .OK, let url = panel.url else { return }
            self.write(png, to: url, folderName: url.deletingLastPathComponent().lastPathComponent)
        }
    }

    private func write(_ png: Data, to url: URL, folderName: String) {
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            host?.captureToast("Couldn't save the Capture")
            return
        }
        used(.save)
        // Library › Media and the Library button's recent files (LIB-1); never a private window's.
        LibraryFiles.shared.recordCapture(url, isPrivate: host?.captureIsPrivate ?? true)
        let toast = host
        finish()
        toast?.captureToast("Saved to \(folderName)")
        lastSaved = url
    }
    /// Where the last Save went (the scripted check reads it).
    private(set) var lastSaved: URL?

    func share() {
        guard let image = confirmedImage(), let png = Self.png(image, scale: resultScale) else { return }
        // Each share owns its directory: another window must not delete a service's in-flight file.
        removeShareFile()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Airc Captures", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(CaptureFileName.make(url: siteURL, date: Date()))
        guard (try? png.write(to: url, options: .atomic)) != nil else { return host?.captureToast("Couldn't share the Capture") ?? () }
        shareFile = url
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        Self.presentShare(picker, [url], overlay.shareAnchor)
    }
    /// The file the share sheet was given.
    var sharedFile: URL? { shareFile }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Dismissed: the selection stays for another try.
        guard service != nil else { removeShareFile(); return }
    }

    private func removeShareFile() {
        guard let url = shareFile else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        shareFile = nil
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { didShare() }
    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        removeShareFile()
        host?.captureToast("Couldn't share the Capture")
    }

    func didShare() {
        used(.share)
        let toast = host
        finish()
        toast?.captureToast("Shared Capture")
    }

    /// The page the file is named after: the top page under the selection.
    private var siteURL: URL? {
        if fullPagePicture != nil || portrait != nil, let tab = fullPageTab { return tab.url }
        let sel = overlay.selection ?? overlay.bounds
        return shots.last { $0.frame.intersects(sel) }?.tab.url ?? shots.last?.tab.url
    }

    // MARK: ⌘ held: the element under the pointer

    private var elementAsk: (point: CGPoint, inFlight: Bool)?

    /// Asks the page under `p` for the element there (one question at a time; the latest point wins).
    func hoverElement(at p: CGPoint) {
        guard phase == .selecting else { return }
        if elementAsk?.inFlight == true { elementAsk?.point = p; return }
        elementAsk = (p, true)
        guard let shot = shots.last(where: { $0.frame.contains(p) }) else {
            elementAsk = nil
            overlay.element = nil
            return
        }
        let css = CaptureGeometry.cssPoint(p, in: shot.frame, zoom: shot.tab.zoomFactor)
        let script = """
        (function(x, y) {
          var e = document.elementFromPoint(x, y);
          if (!e) return null;
          var r = e.getBoundingClientRect();
          while (e.parentElement && e.parentElement !== document.documentElement && (r.width < 12 || r.height < 12)) {
            e = e.parentElement; r = e.getBoundingClientRect();
          }
          return [r.left, r.top, r.width, r.height];
        })(\(Double(css.x)), \(Double(css.y)))
        """
        shot.tab.evaluate(script) { [weak self] value in
            guard let self, !self.ended else { return }
            let asked = self.elementAsk?.point ?? p
            self.elementAsk = nil
            if let a = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), a.count == 4, self.overlay.commandHeld {
                self.overlay.element = CaptureGeometry.elementRect(css: CGRect(x: a[0], y: a[1], width: a[2], height: a[3]), in: shot.frame,
                                                                   zoom: shot.tab.zoomFactor, bounds: self.overlay.bounds)
            } else {
                self.overlay.element = nil
            }
            if asked != p, self.overlay.commandHeld { self.hoverElement(at: asked) }
        }
    }
}

/// Makes the TIFF only when a pasteboard reader asks for it, at the PNG's resolution.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let image: CGImage
    let scale: CGFloat
    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(1, scale)
    }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        item.setData(rep.tiffRepresentation ?? Data(), forType: type)
    }
}

// MARK: - The overlay

/// Over the page card only: the frozen page, dimmed outside the selection, with its frame, handles, size and the bar.
final class CaptureOverlayView: NSView {
    weak var session: CaptureSession?
    var palette: Palette?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The selection in points, nil before the first drag.
    var selection: CGRect? { didSet { if selection != oldValue { onSelectionChange?(selection) } } }
    var onSelectionChange: ((CGRect?) -> Void)?
    /// The element ⌘ points at.
    var element: CGRect? { didSet { if element != oldValue { update() } } }
    private(set) var commandHeld = false
    /// The page as Capture pictured it, drawn over the live page so what's shown is what's taken.
    var frozen: CGImage? { didSet { pictureLayer.contents = frozen } }

    private let pictureLayer = CALayer()
    /// Capture Full Page's picture, scaled to fit the card above the bar.
    private let previewLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private var handleLayers: [CALayer] = []
    private let hint = CapturePill()
    private let readout = CapturePill()
    let bar = CaptureBar()

    private enum Drag {
        case new(anchor: CGPoint)
        case move(from: CGPoint, original: CGRect)
        case resize(CaptureGeometry.Handle, original: CGRect)
    }
    private var drag: Drag?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = true
        layer.cornerRadius = AircMetrics.Window.cardRadius
        layer.cornerCurve = .continuous
        for l in [pictureLayer, dimLayer, previewLayer, hoverLayer, edgeLayer] as [CALayer] {
            l.actions = ["contents": NSNull(), "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer.addSublayer(l)
        }
        pictureLayer.contentsGravity = .resize
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.isHidden = true
        previewLayer.borderWidth = 0.5
        previewLayer.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        previewLayer.shadowColor = NSColor.black.cgColor
        previewLayer.shadowOpacity = 0.4
        previewLayer.shadowRadius = 14
        previewLayer.shadowOffset = CGSize(width: 0, height: -4)
        previewLayer.magnificationFilter = .trilinear
        previewLayer.minificationFilter = .trilinear
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        edgeLayer.fillColor = nil
        edgeLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        edgeLayer.lineWidth = 1
        edgeLayer.shadowColor = NSColor.black.cgColor
        edgeLayer.shadowOpacity = 0.35
        edgeLayer.shadowRadius = 1.5
        edgeLayer.shadowOffset = .zero
        hoverLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        hoverLayer.strokeColor = NSColor.controlAccentColor.cgColor
        hoverLayer.lineWidth = 1.5
        for _ in CaptureGeometry.Handle.allCases {
            let h = CALayer()
            h.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            h.cornerRadius = 4.5
            h.backgroundColor = NSColor.white.cgColor
            h.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
            h.borderWidth = 0.5
            h.shadowColor = NSColor.black.cgColor
            h.shadowOpacity = 0.3
            h.shadowRadius = 2
            h.shadowOffset = CGSize(width: 0, height: -0.5)
            h.actions = ["position": NSNull(), "hidden": NSNull()]
            layer.addSublayer(h)
            handleLayers.append(h)
        }
        hint.text = Self.hintText
        readout.small = true
        for v in [hint, readout, portraitControls, bar] as [NSView] { addSubview(v) }
        bar.overlay = self
        portraitControls.isHidden = true
        portraitControls.onChange = { [weak self] style in self?.session?.portraitStyleChanged(style) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    func appear() {
        update()
        guard let layer else { return }
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
    }

    func disappear() {
        guard let layer else { return removeFromSuperview() }
        layer.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { [weak self] in self?.removeFromSuperview() }
    }

    /// Where the share sheet hangs from.
    var shareAnchor: NSView { bar.shareButton.isHidden ? bar : bar.shareButton }

    static let hintText = "Drag to capture · Space for the visible page · F for the full page · P for a portrait · Hold ⌘ to pick an element · Esc to cancel"
    /// Arc's words while a full page is being taken.
    static let progressText = "Capture in Progress… · Esc to stop"

    /// A portrait's controls (PortraitCapture.swift), under its preview.
    let portraitControls = PortraitControls()

    /// What the preview shows: Capture Full Page's picture or a portrait, with its pixels per point.
    private var previewSource: (image: CGImage, scale: CGFloat)? {
        guard let s = session, s.phase == .confirmed else { return nil }
        if let p = s.fullPagePicture { return (p.image, p.scale) }
        if s.portrait != nil, let r = s.result { return (r, s.resultScale) }
        return nil
    }

    /// Where a full page's picture or a portrait shows: as large as fits above the bar (and a portrait's controls),
    /// centred, never larger than its points.
    var previewFrame: CGRect? {
        guard let p = previewSource else { return nil }
        let room = bounds.insetBy(dx: 32, dy: 0)
        let top: CGFloat = 46, bottom: CGFloat = session?.portrait != nil ? 122 : 70
        let avail = CGSize(width: room.width, height: max(40, bounds.height - top - bottom))
        let size = CGSize(width: CGFloat(p.image.width) / p.scale, height: CGFloat(p.image.height) / p.scale)
        let k = min(1, avail.width / size.width, avail.height / size.height)
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: top, width: w, height: h)
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        update()
    }

    func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        pictureLayer.frame = b
        dimLayer.frame = b
        edgeLayer.frame = b
        hoverLayer.frame = b
        let path = CGMutablePath()
        path.addRect(b)
        let preview = previewFrame
        let capturing = session?.phase == .capturing
        // A full page shows over the dimmed card instead of a selection.
        let sel = preview == nil && !capturing ? selection.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } : nil
        if let sel { path.addRect(sel) }
        dimLayer.path = path
        previewLayer.isHidden = preview == nil
        if let preview {
            let image = previewSource?.image
            if (previewLayer.contents as AnyObject?) !== (image as AnyObject?) { previewLayer.contents = image }
            previewLayer.frame = preview
            previewLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: preview.size), transform: nil)
        } else {
            previewLayer.contents = nil
        }
        edgeLayer.path = sel.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        let showHover = element != nil && commandHeld && drag == nil && session?.phase == .selecting
        hoverLayer.path = showHover ? element.map { CGPath(roundedRect: $0, cornerWidth: 3, cornerHeight: 3, transform: nil) } : nil
        let confirmed = session?.phase == .confirmed
        let handles = sel != nil && !confirmed && min(sel!.width, sel!.height) >= 18
        for (h, l) in zip(CaptureGeometry.Handle.allCases, handleLayers) {
            l.isHidden = !handles
            if let sel { l.position = h.point(on: sel) }
        }
        let palette = self.palette
        hint.palette = palette
        readout.palette = palette
        bar.palette = palette
        hint.isHidden = !capturing && (sel != nil || drag != nil || preview != nil)
        hint.text = capturing ? Self.progressText : Self.hintText
        if !hint.isHidden {
            let s = hint.fittingSize
            hint.frame = NSRect(x: (b.width - s.width) / 2, y: 14, width: s.width, height: s.height)
        }
        if let preview, let portrait = session?.portrait, let layout = portrait.layout {
            readout.text = "Portrait · \(Int(layout.canvas.width)) × \(Int(layout.canvas.height))"
            let s = readout.fittingSize
            readout.frame = NSRect(x: ((b.width - s.width) / 2).rounded(), y: max(6, preview.minY - s.height - 8), width: s.width, height: s.height)
            readout.isHidden = false
        } else if let preview, let p = session?.fullPagePicture {
            // The page's size in points, and how much of it a very long page's picture holds.
            readout.text = p.truncated
                ? "Full page · the first \(Int(p.capturedPoints.height)) of \(Int(p.pagePoints.height)) pt"
                : "Full page · \(Int(p.pagePoints.width)) × \(Int(p.pagePoints.height))"
            let s = readout.fittingSize
            readout.frame = NSRect(x: ((b.width - s.width) / 2).rounded(), y: max(6, preview.minY - s.height - 8), width: s.width, height: s.height)
            readout.isHidden = false
        } else if let sel {
            readout.text = "\(Int(sel.width)) × \(Int(sel.height))"
            let s = readout.fittingSize
            var y = sel.minY - s.height - 6
            if y < 6 { y = sel.minY + 6 }
            readout.frame = NSRect(x: min(max(6, sel.minX), b.width - s.width - 6), y: y, width: s.width, height: s.height)
            readout.isHidden = confirmed
        } else {
            readout.isHidden = true
        }
        bar.mode = capturing ? .capturing : confirmed ? .confirmed : sel == nil ? .start : .selecting
        // A portrait's controls under its preview; the bar under them.
        portraitControls.isHidden = preview == nil || session?.portrait == nil
        portraitControls.palette = palette
        var anchor = preview ?? sel
        if let preview, !portraitControls.isHidden {
            let s = portraitControls.fittingSize
            let f = NSRect(x: (preview.midX - s.width / 2).rounded(), y: preview.maxY + 12, width: s.width, height: s.height)
            portraitControls.frame = f
            anchor = preview.union(f)
        }
        bar.isHidden = drag != nil || (bar.mode == .selecting && (sel!.width < CaptureGeometry.minimumSide || sel!.height < CaptureGeometry.minimumSide))
        if !bar.isHidden {
            let s = bar.fittingSize
            if let anchor {
                var y = anchor.maxY + 10
                if y + s.height > b.height - 8 { y = anchor.minY - s.height - 10 }
                if y < 8 { y = anchor.maxY - s.height - 10 }
                let x = min(max(8, anchor.midX - s.width / 2), b.width - s.width - 8)
                bar.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
            } else {
                // Before a selection, and while a full page is taken: at the card's foot.
                bar.frame = NSRect(x: ((b.width - s.width) / 2).rounded(), y: b.height - s.height - 18, width: s.width, height: s.height)
            }
        }
    }

    // MARK: Pointer

    override func cursorUpdate(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }

    private func pointerMoved(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        commandHeld = event.modifierFlags.contains(.command)
        setCursor(cursor(at: p))
        if commandHeld, drag == nil { session?.hoverElement(at: p) } else if element != nil { element = nil }
    }

    override func flagsChanged(with event: NSEvent) {
        commandHeld = event.modifierFlags.contains(.command)
        let p = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if commandHeld { session?.hoverElement(at: p) } else { element = nil }
        update()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if session?.phase == .capturing || previewFrame != nil { return .arrow }
        guard let sel = selection, session?.phase == .selecting else { return .crosshair }
        switch CaptureGeometry.handle(at: p, on: sel) {
        case .left?, .right?: return .resizeLeftRight
        case .top?, .bottom?: return .resizeUpDown
        case .some: return .crosshair
        case nil: return sel.contains(p) ? .openHand : .crosshair
        }
    }

    override func scrollWheel(with event: NSEvent) {}   // the picture is frozen: the page doesn't scroll under it
    override func rightMouseDown(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        pressed(at: convert(event.locationInWindow, from: nil), clicks: event.clickCount, command: event.modifierFlags.contains(.command))
    }
    override func mouseDragged(with event: NSEvent) { dragged(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { released(at: convert(event.locationInWindow, from: nil)) }

    /// The handlers behind the mouse events, in overlay points (the scripted check drives these).
    func pressed(at p: CGPoint, clicks: Int = 1, command: Bool = false) {
        guard let session, !session.isEnded, session.phase != .capturing else { return }
        // A full page stays up for a press on it; elsewhere a press starts a new selection (Arc's Retake).
        if let preview = previewFrame, preview.contains(p) { return }
        if session.phase == .confirmed { session.reopen() }
        if clicks >= 2, let sel = selection, sel.contains(p) { return session.confirm() }
        dragged = false
        if command, let e = element {
            drag = nil
            selection = e
            element = nil
            return update()
        }
        if let sel = selection, let h = CaptureGeometry.handle(at: p, on: sel) {
            drag = .resize(h, original: sel)
        } else if let sel = selection, sel.contains(p) {
            drag = .move(from: p, original: sel)
            setCursor(.closedHand)
        } else {
            drag = .new(anchor: CGPoint(x: p.x.rounded(), y: p.y.rounded()))
        }
        update()
    }

    func dragged(to p: CGPoint) {
        guard let d = drag else { return }
        dragged = true
        switch d {
        case let .new(anchor):
            selection = CaptureGeometry.clamp(CGRect(x: anchor.x, y: anchor.y, width: p.x - anchor.x, height: p.y - anchor.y), to: bounds)
        case let .move(from, original):
            selection = CaptureGeometry.move(original, by: CGVector(dx: p.x - from.x, dy: p.y - from.y), in: bounds)
        case let .resize(h, original):
            selection = CaptureGeometry.resize(original, handle: h, to: p, in: bounds)
        }
        update()
    }

    func released(at p: CGPoint) {
        guard let d = drag else { return }
        if dragged { dragged(to: p) }
        drag = nil
        if case .new = d, let sel = selection, sel.width < CaptureGeometry.minimumSide || sel.height < CaptureGeometry.minimumSide {
            selection = nil   // a click outside the selection clears it
        }
        setCursor(cursor(at: p))
        update()
    }

    /// Only the key window sets the pointer (a scripted run's events never change the owner's).
    private func setCursor(_ cursor: NSCursor) {
        if window?.isKeyWindow == true { cursor.set() }
    }

    /// Arrow keys move the selection by a point (⇧: ten).
    func nudge(keyCode: UInt16, by n: CGFloat) {
        guard let sel = selection, session?.phase == .selecting else { return }
        let d: CGVector
        switch keyCode {
        case 123: d = CGVector(dx: -n, dy: 0)
        case 124: d = CGVector(dx: n, dy: 0)
        case 125: d = CGVector(dx: 0, dy: n)
        default: d = CGVector(dx: 0, dy: -n)
        }
        selection = CaptureGeometry.move(sel, by: d, in: bounds)
        update()
    }
}

/// A small rounded label on the panel colours: the hint at the top, the size beside the selection.
final class CapturePill: NSView {
    private let label = NSTextField(labelWithString: "")
    var small = false { didSet { label.font = (small ? AircFont.caption : AircFont.callout.weight(.medium)).appFont } }
    var text: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue; needsLayout = true } }
    }
    var palette: Palette? {
        didSet {
            guard let p = palette, p != oldValue else { return }
            label.textColor = p.panelText
            layer?.backgroundColor = p.panelBackground.withAlphaComponent(0.92).cgColor
            layer?.borderColor = p.panelBorder.cgColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.apply(.toast)
        label.font = AircFont.callout.weight(.medium).appFont
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The label's size with room for the text field's own insets (an exact fit clips the last glyph).
    private var labelSize: NSSize {
        let s = label.cell?.cellSize ?? label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + 4, height: ceil(s.height))
    }

    override var fittingSize: NSSize {
        let h: CGFloat = small ? 20 : 28
        return NSSize(width: labelSize.width + (small ? 12 : 22), height: h)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let s = labelSize
        label.frame = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }
}

/// At the card's foot before a selection (Visible Page, Full Page, Portrait); under the selection "Capture" while it's
/// being made; then Copy, Save and Share (under a full page's picture or a portrait too).
final class CaptureBar: NSView {
    weak var overlay: CaptureOverlayView?
    let visibleButton = CaptureBarButton(title: "Visible Page", symbol: "rectangle.dashed")
    let fullPageButton = CaptureBarButton(title: "Full Page", symbol: "arrow.up.and.down.text.horizontal")
    /// Arc's Portrait Mode (its lotus-like symbol).
    let portraitButton = CaptureBarButton(title: "Portrait", symbol: "camera.macro")
    let captureButton = CaptureBarButton(title: "Capture", symbol: "return")
    let copyButton = CaptureBarButton(title: "Copy", symbol: "doc.on.doc")
    let saveButton = CaptureBarButton(title: "Save", symbol: "arrow.down.circle")
    let shareButton = CaptureBarButton(title: "Share", symbol: "square.and.arrow.up")
    let closeButton = CaptureBarButton(title: nil, symbol: "xmark")
    override var isFlipped: Bool { true }

    enum Mode { case start, selecting, capturing, confirmed }
    var mode = Mode.selecting {
        didSet {
            guard mode != oldValue else { return }
            visibleButton.isHidden = mode != .start
            fullPageButton.isHidden = mode != .start
            portraitButton.isHidden = mode != .start
            captureButton.isHidden = mode != .selecting
            for b in [copyButton, saveButton, shareButton] { b.isHidden = mode != .confirmed }
            needsLayout = true
        }
    }
    var confirmed: Bool { mode == .confirmed }
    var palette: Palette? {
        didSet {
            guard let p = palette, p != oldValue else { return }
            layer?.backgroundColor = p.panelBackground.cgColor
            layer?.borderColor = p.panelBorder.cgColor
            for b in buttons { b.palette = p }
        }
    }
    private var buttons: [CaptureBarButton] { [visibleButton, fullPageButton, portraitButton, captureButton, copyButton, saveButton, shareButton, closeButton] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.apply(.toast)
        visibleButton.toolTip = "Select the whole visible page (Space)"
        fullPageButton.toolTip = "Capture the whole page, top to bottom (F). Option-click: in Portrait Mode"
        portraitButton.toolTip = "Capture in Portrait Mode: the page framed on a colour or your desktop picture (P). Option-click: copy it at once"
        captureButton.toolTip = "Capture the selection (Return)"
        copyButton.toolTip = "Copy the picture (⌘C)"
        saveButton.toolTip = "Save to Downloads (⌘S). Option-click or ⇧⌘S to choose a folder"
        shareButton.toolTip = "Share the picture"
        closeButton.toolTip = "Cancel (Esc)"
        visibleButton.action = { [weak self] in self?.overlay?.session?.toggleFullPage() }
        // ⌥ as in Arc: on Full Page a full-page portrait; on Portrait, copied at once in the remembered style.
        fullPageButton.action = { [weak self] in
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { self?.overlay?.session?.capturePortrait(fullPage: true) }
            else { self?.overlay?.session?.captureFullPage() }
        }
        portraitButton.action = { [weak self] in
            self?.overlay?.session?.capturePortrait(quick: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        }
        captureButton.action = { [weak self] in self?.overlay?.session?.confirm() }
        copyButton.action = { [weak self] in self?.overlay?.session?.copyImage() }
        saveButton.action = { [weak self] in self?.overlay?.session?.save() }
        shareButton.action = { [weak self] in self?.overlay?.session?.share() }
        closeButton.action = { [weak self] in self?.overlay?.session?.cancel() }
        captureButton.primary = true
        for b in buttons { addSubview(b) }
        for b in [visibleButton, fullPageButton, portraitButton, copyButton, saveButton, shareButton] { b.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let shown = buttons.filter { !$0.isHidden }
        let w = shown.reduce(0) { $0 + $1.fittingSize.width } + CGFloat(max(0, shown.count - 1)) * 2 + 8
        return NSSize(width: w, height: 36)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for b in buttons where !b.isHidden {
            let s = b.fittingSize
            b.frame = NSRect(x: x, y: 4, width: s.width, height: 28)
            x += s.width + 2
        }
    }
}

/// One of the bar's buttons: a symbol and a title on a plate that shows on hover.
final class CaptureBarButton: NSView {
    var action: (() -> Void)?
    var primary = false { didSet { restyle() } }
    var palette: Palette? { didSet { restyle() } }
    private let glyph = NSImageView()
    private let label: NSTextField?
    private let symbol: String
    private var hovered = false { didSet { restyle() } }
    private var down = false { didSet { restyle() } }

    init(title: String?, symbol: String) {
        self.symbol = symbol
        label = title.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
        if let label {
            label.font = AircFont.body.weight(.medium).appFont
            addSubview(label)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? "Cancel")
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { action?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var fittingSize: NSSize {
        guard let label else { return NSSize(width: 28, height: 28) }
        let text: CGFloat = ceil((label.cell?.cellSize ?? label.intrinsicContentSize).width) + 4
        // Insets 10 + glyph 16 + gap 6 + text + 10.
        return NSSize(width: text + 42, height: 28)
    }

    override func layout() {
        super.layout()
        let g: CGFloat = 16
        if let label {
            let s = label.cell?.cellSize ?? label.intrinsicContentSize
            glyph.frame = NSRect(x: 10, y: (bounds.height - g) / 2, width: g, height: g)
            label.frame = NSRect(x: 10 + g + 6, y: (bounds.height - s.height) / 2, width: ceil(s.width) + 4, height: ceil(s.height))
        } else {
            glyph.frame = NSRect(x: (bounds.width - g) / 2, y: (bounds.height - g) / 2, width: g, height: g)
        }
    }

    private func restyle() {
        guard let p = palette else { return }
        let fg = primary ? NSColor.white : p.panelText
        let config = NSImage.SymbolConfiguration(pointSize: label == nil ? 11 : 13, weight: .medium)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph.contentTintColor = primary ? fg : (label == nil ? p.panelSecondary : p.panelText)
        label?.textColor = fg
        let fill: NSColor
        if primary {
            fill = NSColor.controlAccentColor.withAlphaComponent(down ? 0.8 : hovered ? 0.92 : 1)
        } else {
            fill = down ? p.panelSelection : hovered ? p.panelSelection.withAlphaComponent(0.7) : .clear
        }
        layer?.backgroundColor = fill.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { down = true }
    override func mouseDragged(with event: NSEvent) { down = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        if inside { action?() }
    }
}

// MARK: - The windows

extension WindowController: CaptureHost {
    var captureWindow: NSWindow { window }
    var captureRoot: NSView { root }
    var captureCardFrame: NSRect { card.frame }
    var capturePages: [EngineTab] {
        var tabs: [EngineTab] = shownSplitID != nil ? splitContainer.tabIDs.compactMap { engineTab(for: $0) }
            : shownTabID.flatMap { engineTab(for: $0) }.map { [$0] } ?? []
        if let p = peek?.page { tabs.append(p) }
        return tabs
    }
    var capturePalette: Palette { currentPalette }
    var captureIsPrivate: Bool { false }
    func captureToast(_ text: String) { showToast(text) }
    /// A note's editor, in the card or a split's pane (Notes/NoteSplit.swift): Capture takes it as drawn.
    var captureViews: [NSView] {
        guard multiWindow.elsewhereTabID == nil else { return [] }
        if shownSplitID != nil { return notePaneViews }
        return shownNote.map { [$0.view] } ?? []
    }
    var captureFocusedPage: EngineTab? { peek?.page ?? shownTabID.flatMap { engineTab(for: $0) } }

    /// ⇧⌘2; `fullPage`: Capture Full Page; `portrait`: Capture in Portrait Mode (of the full page with both).
    func startCapture(fullPage: Bool = false, portrait: Bool = false) { CaptureSession.toggle(self, fullPage: fullPage, portrait: portrait) }
}

extension PrivateWindowController: CaptureHost {
    var captureWindow: NSWindow { window }
    var captureRoot: NSView { root }
    var captureCardFrame: NSRect { card.frame }
    var capturePages: [EngineTab] { shownPage.map { [$0] } ?? [] }
    var capturePalette: Palette { palette }
    var captureIsPrivate: Bool { true }
    func captureToast(_ text: String) { showToast(text) }

    func startCapture(fullPage: Bool = false, portrait: Bool = false) { CaptureSession.toggle(self, fullPage: fullPage, portrait: portrait) }
}

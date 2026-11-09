// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import ImageIO
import PDFKit
import WebKit
#if canImport(AircCore)
import AircCore
#endif

/// Arc's "Capture Full Page" (docs/user/capture.md): the whole length of the page, not only what's in the window, at
/// the window's pixels per point. No engine change and no screen capture:
///   - Chromium: DevTools' `Page.captureScreenshot` with `captureBeyondViewport`, in tiles at most `tileHeight` pixels
///     tall, each drawn into the one picture and let go (the engine's own full-size screenshot, as DevTools' "Capture
///     full size screenshot"). Its clip is in points. Fixed parts are painted once, where they are on screen with the
///     page at its top: a fixed header at the top, a fixed footer where the window's foot is.
///   - WebKit: `createPDF` of the page's whole length (WebKit paints the document, vector), in parts of `pdfChunk`
///     points (a PDF page stops at 14,400), rasterised at the same pixels per point. Fixed parts once, laid out for
///     the whole page (a fixed footer at its foot), or for the first part on a page longer than that.
/// Both take the page as at its top: it's scrolled there for the picture and back afterwards.
/// Memory is bounded: a page whose picture would pass `maxPixels` is taken at fewer pixels per point (down to 1), and
/// one still longer is cut at `maxPixels` (and `maxHeight`), which `Picture.truncated` says.
enum FullPageCapture {
    struct Picture {
        let image: CGImage
        /// Pixels per point of the picture (the window's backing scale, or less for a very long page).
        let scale: CGFloat
        /// The page's whole length in points, and how much of it the picture holds.
        let pagePoints: CGSize
        let capturedPoints: CGSize
        var truncated: Bool { capturedPoints.height + 0.5 < pagePoints.height }
    }

    enum Failure: Error, Equatable {
        case unsupported, noContent, cancelled, timedOut
        case engine(String)
    }

    /// The most pixels a picture may have: 48 megapixels (about 190 MB while it's made), 2880 × 16 666 at 2×.
    static var maxPixels = 48_000_000
    /// The tallest a picture may be, in pixels.
    static var maxHeight = 32_000
    /// The tallest tile Chromium is asked for at once, in pixels.
    static var tileHeight = 4096
    /// The longest part WebKit is asked for at once, in points (a PDF page can't pass 14,400).
    static var pdfChunk: CGFloat = 14_000
    /// How long the whole capture may take.
    static var timeout: TimeInterval = 30

    #if AIRC_TESTING
    /// What the last Chromium capture measured (the check reports it).
    static var lastDiagnostics: [String: Any] = [:]
    #endif

    /// The picture of `tab`'s whole page at `scale` pixels per point. `isCurrent` false (cancelled, the page closed or
    /// navigated) ends it without an answer that counts; `progress` gets 0…1.
    static func capture(_ tab: EngineTab, scale: CGFloat, isCurrent: @escaping () -> Bool,
                        progress: @escaping (Double) -> Void = { _ in },
                        completion: @escaping (Result<Picture, Failure>) -> Void) {
        var answered = false
        let url = tab.url
        let current = { isCurrent() && !tab.isClosed && tab.url == url }
        let finish: (Result<Picture, Failure>) -> Void = { result in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                completion(current() ? result : .failure(.cancelled))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.failure(.timedOut)) }
        if let web = tab as? WebKitTab {
            return captureWebKit(web.webView, zoom: tab.zoomFactor, scale: scale, isCurrent: { current() && !answered }, finish)
        }
        #if canImport(AircCore)
        if let chromium = tab as? ChromiumTab {
            return captureChromium(chromium.core, zoom: tab.zoomFactor, scale: scale, isCurrent: { current() && !answered },
                                   progress: progress, finish)
        }
        #endif
        finish(.failure(.unsupported))
    }

    /// The size the picture can be: `points` (width × length) at `scale`, smaller per point (not below 1) to fit
    /// `maxPixels`, then cut to fit `maxPixels` and `maxHeight`. Returns pixels per point and the points it holds.
    static func plan(points: CGSize, scale: CGFloat) -> (scale: CGFloat, points: CGSize) {
        guard points.width >= 1, points.height >= 1 else { return (scale, points) }
        var s = scale
        let area = Double(points.width * points.height)
        if area * Double(s * s) > Double(maxPixels) { s = max(1, CGFloat((Double(maxPixels) / area).squareRoot())) }
        // Whole pixels per row, so tiles meet without a seam.
        if s > 1 { s = (s * points.width).rounded(.down) / points.width }
        var height = points.height
        height = min(height, CGFloat(maxPixels) / (points.width * s * s))
        height = min(height, CGFloat(maxHeight) / s)
        return (s, CGSize(width: points.width, height: height.rounded(.down)))
    }

    // MARK: Chromium

    #if canImport(AircCore)
    private static func captureChromium(_ core: AircTab, zoom: Double, scale: CGFloat, isCurrent: @escaping () -> Bool,
                                        progress: @escaping (Double) -> Void, _ done: @escaping (Result<Picture, Failure>) -> Void) {
        // The page as at its top (its fixed parts where they are then), and back where it was afterwards.
        core.devToolsCall("Runtime.evaluate", params: ["expression": scrollToTop, "awaitPromise": true, "returnByValue": true], timeout: 5) { reply, _ in
            let saved = ((reply?["result"] as? [AnyHashable: Any])?["value"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            let finish: (Result<Picture, Failure>) -> Void = { result in
                if let saved, saved.count == 2, saved != [0, 0] {
                    core.devToolsCall("Runtime.evaluate", params: ["expression": scrollBack(saved[0], saved[1])], timeout: 5) { _, _ in }
                }
                done(result)
            }
            DispatchQueue.main.async { measureChromium(core, zoom: zoom, scale: scale, isCurrent: isCurrent, progress: progress, finish) }
        }
    }

    private static func measureChromium(_ core: AircTab, zoom: Double, scale: CGFloat, isCurrent: @escaping () -> Bool,
                                        progress: @escaping (Double) -> Void, _ finish: @escaping (Result<Picture, Failure>) -> Void) {
        guard isCurrent() else { return finish(.failure(.cancelled)) }
        core.devToolsCall("Page.getLayoutMetrics", params: nil, timeout: 10) { reply, error in
            DispatchQueue.main.async {
                guard isCurrent() else { return finish(.failure(.cancelled)) }
                guard let reply, let viewport = reply["cssLayoutViewport"] as? [String: Any], let content = reply["cssContentSize"] as? [String: Any],
                      let cssWidth = (viewport["clientWidth"] as? NSNumber)?.doubleValue, let cssHeight = (content["height"] as? NSNumber)?.doubleValue,
                      cssWidth >= 1, cssHeight >= 1 else { return finish(.failure(error.map(Failure.engine) ?? .noContent)) }
                // The clip is in points (CSS pixels × page zoom), as measured: at 150 % a CSS-pixel clip took two thirds of
                // the page, each part half as tall again.
                let z = max(0.25, zoom)
                let pagePoints = CGSize(width: (cssWidth * z).rounded(), height: (cssHeight * z).rounded())
                let (s, captured) = plan(points: pagePoints, scale: scale)
                let width = Int((captured.width * s).rounded()), height = Int((captured.height * s).rounded())
                guard width > 0, height > 0, let ctx = context(width: width, height: height) else { return finish(.failure(.noContent)) }
                let clipWidth = Double(captured.width), clipHeight = Double(captured.height)
                // Pixels per point at the clip's scale 1 (the display's): the scale that gives the picture's.
                let calibrate: [String: Any] = ["format": "png", "captureBeyondViewport": true, "fromSurface": true,
                                                "clip": ["x": 0, "y": 0, "width": clipWidth, "height": min(16, clipHeight), "scale": 1]]
                core.devToolsCall("Page.captureScreenshot", params: calibrate, timeout: 10) { reply, error in
                    DispatchQueue.main.async {
                        guard isCurrent() else { return finish(.failure(.cancelled)) }
                        guard let probe = (reply?["data"] as? String).flatMap(decode), probe.width > 0 else {
                            return finish(.failure(.engine(error ?? "no picture")))
                        }
                        let perPoint = Double(probe.width) / clipWidth
                        let clipScale = Double(s) / perPoint
                        #if AIRC_TESTING
                        lastDiagnostics = ["cssWidth": cssWidth, "cssHeight": cssHeight, "zoom": z, "scale": Double(s), "perPoint": perPoint,
                                           "clipScale": clipScale, "probe": [probe.width, probe.height], "picture": [width, height]]
                        #endif
                        let tilePoints = max(1, (Double(tileHeight) / Double(s)).rounded(.down))
                        var y = 0.0
                        func next() {
                            guard isCurrent() else { return finish(.failure(.cancelled)) }
                            guard y < clipHeight else {
                                guard let image = ctx.makeImage() else { return finish(.failure(.noContent)) }
                                return finish(.success(Picture(image: image, scale: s, pagePoints: pagePoints, capturedPoints: captured)))
                            }
                            let h = min(tilePoints, clipHeight - y)
                            let params: [String: Any] = ["format": "png", "captureBeyondViewport": true, "fromSurface": true,
                                                         "clip": ["x": 0, "y": y, "width": clipWidth, "height": h, "scale": clipScale]]
                            core.devToolsCall("Page.captureScreenshot", params: params, timeout: 15) { reply, error in
                                // Decoded off the main thread; drawn in order, one tile in memory at a time.
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let tile = (reply?["data"] as? String).flatMap(decode)
                                    DispatchQueue.main.async {
                                        guard isCurrent() else { return finish(.failure(.cancelled)) }
                                        guard let tile else { return finish(.failure(.engine(error ?? "no picture"))) }
                                        let top = (y * Double(s)).rounded()
                                        // CG counts from the bottom: the tile's top row goes `top` pixels down.
                                        ctx.draw(tile, in: CGRect(x: 0, y: Double(height) - top - Double(tile.height),
                                                                  width: Double(width), height: Double(tile.height)))
                                        y += h
                                        progress(min(1, y / clipHeight))
                                        next()
                                    }
                                }
                            }
                        }
                        next()
                    }
                }
            }
        }
    }
    #endif

    /// Scrolls to the top at once (no smooth scrolling) and answers [x, y] where it was, after a frame (or 150 ms when
    /// the page isn't drawn and frames don't come).
    static let scrollToTop = """
    new Promise(function (done) {
      var x = window.scrollX, y = window.scrollY, answered = false;
      function answer() { if (!answered) { answered = true; done([x, y]); } }
      window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
      requestAnimationFrame(function () { requestAnimationFrame(answer); });
      setTimeout(answer, 150);
    })
    """

    static func scrollBack(_ x: Double, _ y: Double) -> String { "window.scrollTo({ left: \(x), top: \(y), behavior: 'instant' })" }

    /// Fixed elements hidden and sticky ones made to stay in their place (relative, no offsets), through their inline
    /// styles (a page's content security policy doesn't stop that), remembered in Airc's own script world.
    static let holdFixed = """
    var held = [];
    document.querySelectorAll('body *').forEach(function (e) {
      var p = getComputedStyle(e).position;
      if (p !== 'fixed' && p !== 'sticky') return;
      var props = p === 'fixed' ? ['visibility'] : ['position', 'top', 'bottom', 'left', 'right'];
      held.push([e, props.map(function (k) { return [k, e.style.getPropertyValue(k), e.style.getPropertyPriority(k)]; })]);
      if (p === 'fixed') e.style.setProperty('visibility', 'hidden', 'important');
      else ['top', 'bottom', 'left', 'right'].reduce(function (s, k) { s.setProperty(k, 'auto', 'important'); return s; },
                                                   e.style).setProperty('position', 'relative', 'important');
    });
    window.aircFullPageHeld = held;
    return held.length;
    """

    /// Puts back what `holdFixed` changed.
    static let releaseFixed = """
    (window.aircFullPageHeld || []).forEach(function (h) {
      h[1].forEach(function (p) { h[0].style.setProperty(p[0], p[1], p[2]); });
    });
    window.aircFullPageHeld = null;
    return true;
    """

    /// A PNG's pixels from DevTools' base64.
    private static func decode(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        let space = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.setFillColor(NSColor.white.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    // MARK: WebKit

    private static func captureWebKit(_ web: WKWebView, zoom: Double, scale: CGFloat, isCurrent: @escaping () -> Bool,
                                      _ done: @escaping (Result<Picture, Failure>) -> Void) {
        // The page as at its top, as on Chromium, and back where it was afterwards.
        web.callAsyncJavaScript("return await " + scrollToTop, arguments: [:], in: nil, in: .page) { result in
            let saved = ((try? result.get()) as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            let finish: (Result<Picture, Failure>) -> Void = { outcome in
                if let saved, saved.count == 2, saved != [0, 0] { web.evaluateJavaScript(scrollBack(saved[0], saved[1])) { _, _ in } }
                done(outcome)
            }
            renderWebKit(web, zoom: zoom, scale: scale, isCurrent: isCurrent, finish)
        }
    }

    private static func renderWebKit(_ web: WKWebView, zoom: Double, scale: CGFloat, isCurrent: @escaping () -> Bool,
                                     _ done: @escaping (Result<Picture, Failure>) -> Void) {
        // WebKit lays fixed and sticky parts out for each PDF part again: after the first part they're held still (fixed
        // ones hidden, sticky ones in their place), so they show once; put back however it ends.
        var held = false
        let finish: (Result<Picture, Failure>) -> Void = { result in
            if held { web.callAsyncJavaScript(releaseFixed, arguments: [:], in: nil, in: .defaultClient) { _ in } }
            done(result)
        }
        // The page's width (no scroll bar) and whole length, in CSS pixels.
        let js = "[document.documentElement.clientWidth, Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        web.evaluateJavaScript(js) { value, _ in
            guard isCurrent() else { return finish(.failure(.cancelled)) }
            guard let a = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), a.count == 2, a[0] >= 1, a[1] >= 1 else {
                return finish(.failure(.noContent))
            }
            let z = max(0.25, zoom)
            let pagePoints = CGSize(width: (a[0] * z).rounded(), height: (a[1] * z).rounded())
            let (s, captured) = plan(points: pagePoints, scale: scale)
            let width = Int((captured.width * s).rounded()), height = Int((captured.height * s).rounded())
            guard width > 0, height > 0, let ctx = context(width: width, height: height) else { return finish(.failure(.noContent)) }
            // A PDF page is at most 14,400 points long (WebKit's stopped there): the page in parts of `pdfChunk` points,
            // each drawn at its place and let go.
            var y: CGFloat = 0
            var parts = 0
            var boxes: [[Double]] = []
            func next() {
                guard isCurrent() else { return finish(.failure(.cancelled)) }
                guard y < captured.height else {
                    #if AIRC_TESTING
                    lastDiagnostics = ["cssWidth": a[0], "cssHeight": a[1], "zoom": z, "scale": Double(s), "pdfParts": parts, "pdfBoxes": boxes, "picture": [width, height]]
                    #endif
                    guard let image = ctx.makeImage() else { return finish(.failure(.noContent)) }
                    return finish(.success(Picture(image: image, scale: s, pagePoints: pagePoints, capturedPoints: captured)))
                }
                if y > 0, !held {
                    held = true
                    return web.callAsyncJavaScript(holdFixed, arguments: [:], in: nil, in: .defaultClient) { _ in next() }
                }
                let h = min(pdfChunk, captured.height - y)
                let config = WKPDFConfiguration()
                // In the web view's coordinates (points), from the page's top.
                config.rect = CGRect(x: 0, y: y, width: pagePoints.width, height: h)
                web.createPDF(configuration: config) { result in
                    DispatchQueue.main.async {
                        guard isCurrent() else { return finish(.failure(.cancelled)) }
                        guard case .success(let data) = result, let doc = PDFDocument(data: data), let page = doc.page(at: 0), let ref = page.pageRef else {
                            if case .failure(let e) = result { return finish(.failure(.engine(e.localizedDescription))) }
                            return finish(.failure(.noContent))
                        }
                        let box = page.bounds(for: .mediaBox)
                        guard box.width > 0, box.height > 0 else { return finish(.failure(.noContent)) }
                        boxes.append([Double(y), Double(h), Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)])
                        // The part's points onto the picture's pixels at one scale, its top `y` points down (CG counts
                        // from the bottom).
                        let k = CGFloat(width) / box.width
                        ctx.saveGState()
                        ctx.translateBy(x: 0, y: CGFloat(height) - (y * s).rounded() - box.height * k)
                        ctx.scaleBy(x: k, y: k)
                        ctx.translateBy(x: -box.minX, y: -box.minY)
                        ctx.drawPDFPage(ref)
                        ctx.restoreGState()
                        y += h
                        parts += 1
                        next()
                    }
                }
            }
            next()
        }
    }
}

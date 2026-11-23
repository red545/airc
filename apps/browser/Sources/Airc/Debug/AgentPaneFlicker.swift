// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import QuartzCore

/// agentux3 (owner feedback 2026-11-20: "the live page card flickers while the agent works"): a frame-by-frame record
/// of the pane's live card. The window server's pictures of our own window (CGWindowListCreateImage on our window
/// number: no Screen Recording, AIRC_DISABLE_LEGACY_WINDOW_CAPTURE honoured) at ~30 Hz, each one decoded against the
/// fixture page (`page`): a fixed cyan marker (where the page is in the card: bounds jumps) and a 10-bit frame
/// counter the page redraws on every animation frame (red = 1, blue = 0: stale content shows as a counter going back).
/// A frame without the marker is blank (uniform), black, or something else (logged). The app's own state is sampled
/// on the main thread at the same rate (which view, live/copies, context id, layers hidden), so a bad frame can be
/// traced to what changed.
final class AgentPaneFlickerProbe {
    /// The fixture: marker at page (0,0)–(96,96), counter blocks of 96 px from x = 120 at y = 0, a block that slides,
    /// and a tall page to scroll with buttons to click. Fixed elements stay put while the agent scrolls.
    static let page = """
    <title>Flicker fixture</title><style>body{margin:0;background:#f4f1ea;font:22px sans-serif}
    #mk{position:fixed;left:0;top:0;width:96px;height:96px;background:#00c8c8;z-index:3}
    #bits{position:fixed;left:120px;top:0;height:96px;display:flex;z-index:3}#bits i{display:block;width:96px;height:96px}
    #mv{position:fixed;left:0;top:320px;width:220px;height:220px;background:#e0306a;z-index:2}
    .pad{height:5000px;background:linear-gradient(#f4f1ea,#9fb6d8)}
    button{position:absolute;left:40px;width:320px;height:90px;font:22px sans-serif}</style>
    <div id=mk></div><div id=bits></div><div id=mv></div><div class=pad></div>
    <button id=b1 style="top:160px" onclick="this.textContent='Clicked '+(++window.n)">Click me</button>
    <button id=b2 style="top:900px" onclick="this.textContent='Clicked '+(++window.n)">Click me too</button>
    <script>window.n=0;var bits=document.getElementById('bits'),mv=document.getElementById('mv');
    for(var i=0;i<10;i++)bits.appendChild(document.createElement('i'));var kids=bits.children,t0=performance.now();
    function f(){var c=Math.floor(Date.now()*0.06)&1023;
    for(var i=0;i<10;i++)kids[i].style.background=((c>>(9-i))&1)?'#ff2000':'#0020ff';
    mv.style.transform='translateX('+((c*9)%1000)+'px)';requestAnimationFrame(f)}requestAnimationFrame(f)</script>
    """

    struct Frame {
        var t: Double
        /// The counter (0–1023), nil when the marker isn't there.
        var counter: Int?
        /// The marker's box in capture pixels.
        var marker: CGRect?
        /// "ok", "blank", "black", "other", "stale", "jump", "nocapture".
        var verdict = "ok"
        var mean: Double = 0
        var spread: Double = 0
    }

    struct Sample {
        var t: Double
        var state: String
    }

    let window: NSWindow
    /// The capture rectangle, in Quartz global points (top-left origin).
    let rect: CGRect
    let hz: Double
    private(set) var frames: [Frame] = []
    private(set) var samples: [Sample] = []
    private(set) var events: [(t: Double, what: String)] = []
    /// Kept pictures (index → image) for the strip: a few around each bad frame, and a run from the middle.
    private var kept: [Int: CGImage] = [:]
    private var recent: [(Int, CGImage)] = []
    private var keepAfter = 0
    private let queue = DispatchQueue(label: "airc.flicker-probe", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var mainTimer: Timer?
    fileprivate(set) var started = 0.0
    private var captureIndex = 0
    /// Seconds since the record started.
    var elapsed: Double { CACurrentMediaTime() - started }
    private var maxCounter: Int?
    private var lastMarker: CGRect?
    private let lock = NSLock()
    var sampleState: (() -> String)?

    init(window: NSWindow, rect: CGRect, hz: Double = 30) {
        self.window = window
        self.rect = rect
        self.hz = hz
    }

    static var available: Bool {
        ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1"
            && dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") != nil
    }

    /// The capture rectangle for a view (its bounds plus `margin`), in Quartz global points.
    static func rect(of v: NSView, margin: CGFloat = 10) -> CGRect? {
        guard let w = v.window, let main = NSScreen.screens.first else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil)).insetBy(dx: -margin, dy: -margin)
        return CGRect(x: r.minX, y: main.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func event(_ what: String) {
        lock.lock(); events.append((CACurrentMediaTime() - started, what)); lock.unlock()
    }

    func start(seconds: Double, _ done: @escaping () -> Void) {
        started = CACurrentMediaTime()
        let wid = UInt32(window.windowNumber)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(2))
        follower?.started = started
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.captureOne(wid)
            // The follower's picture right after this one (cardflicker: the agent window's own output).
            if let f = self.follower { f.captureOne(UInt32(f.window.windowNumber)) }
        }
        timer = t
        t.resume()
        let m = Timer(timeInterval: 1 / hz, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Sample(t: CACurrentMediaTime() - self.started, state: self.sampleState?() ?? "")
            self.lock.lock(); self.samples.append(s); self.lock.unlock()
        }
        RunLoop.main.add(m, forMode: .common)
        mainTimer = m
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.mainTimer?.invalidate()
            self?.queue.async {
                self?.timer?.cancel()
                DispatchQueue.main.async(execute: done)
            }
        }
    }

    /// One window-server picture, decoded and logged (the timer's queue).
    private func captureOne(_ wid: UInt32) {
        let now = CACurrentMediaTime() - started
        let img = Self.capture(wid, rect)
        var f = img.map { analyse($0, t: now) } ?? Frame(t: now, verdict: "nocapture")
        let i = captureIndex
        if let img { keep(i, img, bad: f.verdict != "ok") }
        if f.verdict == "ok", i == 150 { keepAfter = max(keepAfter, 12) }
        f.t = now
        lock.lock(); frames.append(f); lock.unlock()
        captureIndex += 1
    }

    /// A second probe (another window and rectangle) captured in the same tick, right after this one's picture, on
    /// the same clock; it is never started itself (cardflicker: the agent window's own picture next to the card's).
    var follower: AgentPaneFlickerProbe?

    /// Pictures per second for the record: 30, or AIRC_FLICKER_HZ (cardflicker's 60 Hz diagnosis runs).
    static var defaultHz: Double {
        ProcessInfo.processInfo.environment["AIRC_FLICKER_HZ"].flatMap(Double.init).map { min(120, max(10, $0)) } ?? 30
    }

    private func keep(_ i: Int, _ img: CGImage, bad: Bool) {
        recent.append((i, img))
        if recent.count > 4 { recent.removeFirst() }
        if bad, kept.count < 120 {
            for (j, im) in recent { kept[j] = im }
            keepAfter = max(keepAfter, 4)
        } else if keepAfter > 0 {
            kept[i] = img
            keepAfter -= 1
        }
    }

    static func capture(_ wid: UInt32, _ rect: CGRect) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
        return unsafeBitCast(sym, to: Fn.self)(rect, 1 << 3, wid, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// RGBA pixels of a picture.
    struct Pixels {
        let w: Int, h: Int
        let data: [UInt8]
        init?(_ img: CGImage) {
            let width = img.width, height = img.height
            var d = [UInt8](repeating: 0, count: width * height * 4)
            let ok = d.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }
            w = width; h = height
            data = d
        }
        /// (r, g, b) at x, y from the top-left.
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard x >= 0, y >= 0, x < w, y < h else { return (-1, -1, -1) }
            let i = (y * w + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    static func cyan(_ p: (Int, Int, Int)) -> Bool { p.0 < 90 && p.1 > 140 && p.2 > 140 && abs(p.1 - p.2) < 60 }

    func analyse(_ img: CGImage, t: Double) -> Frame {
        var f = Frame(t: t)
        guard let px = Pixels(img) else { f.verdict = "nocapture"; return f }
        // The marker: cyan pixels in the picture's left half (sampled every 2 px), their box.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, n = 0
        for y in Swift.stride(from: 0, to: px.h * 2 / 3, by: 2) {
            for x in Swift.stride(from: 0, to: px.w / 2, by: 2) where Self.cyan(px.at(x, y)) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); n += 1
            }
        }
        // Grey level spread over a grid (blank / black detection).
        var sum = 0.0, sq = 0.0, cnt = 0.0
        for j in 1...9 { for i in 1...15 {
            let p = px.at(px.w * i / 16, px.h * j / 10)
            let l = 0.3 * Double(p.0) + 0.59 * Double(p.1) + 0.11 * Double(p.2)
            sum += l; sq += l * l; cnt += 1
        } }
        f.mean = sum / cnt
        f.spread = max(0, sq / cnt - f.mean * f.mean).squareRoot()
        guard n >= 6, maxX > minX + 4, maxY > minY + 4 else {
            f.verdict = f.mean < 25 ? "black" : f.spread < 4 ? "blank" : "other"
            return f
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2)
        f.marker = box
        // The counter: block i's centre is (120 + 96 i + 48) page px from the left, at the marker's middle.
        let unit = box.width / 96
        var c = 0
        for i in 0..<10 {
            let p = px.at(Int(box.minX + (168 + 96 * CGFloat(i)) * unit), Int(box.midY))
            c = (c << 1) | (p.0 > p.2 ? 1 : 0)
        }
        f.counter = c
        if let last = lastMarker, abs(last.minX - box.minX) > 3 || abs(last.minY - box.minY) > 3 || abs(last.width - box.width) > 3 {
            f.verdict = "jump"
        }
        lastMarker = box
        if let m = maxCounter {
            let back = (m - c + 1024) % 1024
            // Behind the newest counter shown so far (by less than half the range: more is a wrap).
            if back > 0, back < 512 { if f.verdict == "ok" { f.verdict = "stale" } } else { maxCounter = c }
        } else {
            maxCounter = c
        }
        return f
    }

    // MARK: Results

    struct Summary {
        var frames = 0, ok = 0, blank = 0, black = 0, other = 0, stale = 0, jump = 0, nocapture = 0
        var hz = 0.0
        /// Content changes per second (the counter moved between two pictures).
        var updates = 0.0
        /// Median and largest gap between content changes, ms.
        var medianGap = 0.0, maxGap = 0.0
        var bad: Int { blank + black + other + stale + jump }
        var line: String {
            "\(frames) pictures at \(String(format: "%.1f", hz)) Hz: \(ok) ok, \(blank) blank, \(black) black, \(other) other, \(stale) stale, \(jump) jumps"
                + (nocapture > 0 ? ", \(nocapture) not captured" : "")
                + String(format: "; content %.1f updates/s, gap median %.0f ms, max %.0f ms", updates, medianGap, maxGap)
        }
    }

    func summary(from: Double = 0, to: Double = .infinity) -> Summary {
        lock.lock(); let fs = frames.filter { $0.t >= from && $0.t < to }; lock.unlock()
        var s = Summary()
        s.frames = fs.count
        for f in fs {
            switch f.verdict {
            case "ok": s.ok += 1
            case "blank": s.blank += 1
            case "black": s.black += 1
            case "stale": s.stale += 1
            case "jump": s.jump += 1
            case "nocapture": s.nocapture += 1
            default: s.other += 1
            }
        }
        if let a = fs.first?.t, let b = fs.last?.t, b > a {
            s.hz = Double(fs.count - 1) / (b - a)
            var changes: [Double] = []
            var last: Int?
            for f in fs { if let c = f.counter { if let l = last, l != c { changes.append(f.t) }; last = c } }
            s.updates = Double(changes.count) / (b - a)
            let gaps = zip(changes.dropFirst(), changes).map { ($0 - $1) * 1000 }.sorted()
            if !gaps.isEmpty { s.medianGap = gaps[gaps.count / 2]; s.maxGap = gaps.last ?? 0 }
        }
        return s
    }

    /// The first bad frames with the app's state at that moment and the agent's last step.
    func badLines(limit: Int = 12) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        for (i, f) in frames.enumerated() where f.verdict != "ok" && f.verdict != "nocapture" {
            let s = samples.last { $0.t <= f.t }?.state ?? "?"
            let e = events.last { $0.t <= f.t }.map { "\($0.what) at \(String(format: "%.2f", $0.t)) s" } ?? "none"
            out.append(String(format: "#%d %.3f s %@ (counter %@, mean %.0f, spread %.0f) | app: %@ | last step: %@", i, f.t, f.verdict,
                              f.counter.map(String.init) ?? "–", f.mean, f.spread, s, e))
            if out.count >= limit { break }
        }
        return out
    }

    /// The app-side changes seen by the sampler (state strings that differ from the one before), for the report.
    func stateChanges(limit: Int = 40) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        var last = ""
        for s in samples where s.state != last {
            out.append(String(format: "%.3f s %@", s.t, s.state))
            last = s.state
            if out.count >= limit { break }
        }
        return out
    }

    /// Writes the per-frame log (TSV) and a strip of kept consecutive pictures (PNG) into `dir`.
    func write(to dir: URL, name: String) {
        lock.lock(); let fs = frames; let ss = samples; let ev = events; let keptNow = kept; lock.unlock()
        var tsv = "i\tt\tverdict\tcounter\tmarker\tmean\tspread\tapp\n"
        for (i, f) in fs.enumerated() {
            let s = ss.last { $0.t <= f.t }?.state ?? ""
            tsv += "\(i)\t\(String(format: "%.4f", f.t))\t\(f.verdict)\t\(f.counter.map(String.init) ?? "")\t\(f.marker.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))" } ?? "")\t\(Int(f.mean))\t\(Int(f.spread))\t\(s)\n"
        }
        tsv += "\n# events\n" + ev.map { String(format: "%.4f\t%@", $0.t, $0.what) }.joined(separator: "\n") + "\n"
        try? tsv.write(to: dir.appendingPathComponent("\(name).tsv"), atomically: true, encoding: .utf8)
        // Strips: runs of up to 10 consecutive kept pictures.
        let idx = keptNow.keys.sorted()
        var runs: [[Int]] = []
        for i in idx { if let l = runs.last?.last, l == i - 1, runs[runs.count - 1].count < 10 { runs[runs.count - 1].append(i) } else { runs.append([i]) } }
        for (n, r) in runs.prefix(6).enumerated() {
            let imgs = r.compactMap { keptNow[$0] }
            guard let first = imgs.first else { continue }
            let scale = min(1, 360 / CGFloat(first.width))
            let w = Int(CGFloat(first.width) * scale), h = Int(CGFloat(first.height) * scale)
            let label = 22
            guard let ctx = CGContext(data: nil, width: w * imgs.count + 4 * (imgs.count - 1), height: h + label, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            for (k, im) in imgs.enumerated() {
                let x = k * (w + 4)
                ctx.draw(im, in: CGRect(x: x, y: 0, width: w, height: h))
                let f = fs[r[k]]
                let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ns
                let text = "#\(r[k]) \(String(format: "%.2f", f.t))s \(f.verdict) \(f.counter.map(String.init) ?? "–")"
                (text as NSString).draw(at: NSPoint(x: x + 3, y: h + 4), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                                                                         .foregroundColor: f.verdict == "ok" ? NSColor.black : NSColor.red])
                NSGraphicsContext.restoreGraphicsState()
            }
            if let out = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: out)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-strip\(n + 1).png"))
            }
        }
    }
}
#endif

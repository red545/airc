// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Network
import SwiftUI

/// The marketing shots' photography (`--script marketing`, MarketingScenario.swift): windows on a soft desktop, each
/// with a macOS window's continuous corners, shadow and hairline, its traffic lights in colour, at 2×.
enum MarketingStudio {
    static let scale: CGFloat = 2
    /// Room around a window for its shadow: more below than above, as light falls from the top.
    static let margin = NSEdgeInsets(top: 64, left: 84, bottom: 104, right: 84)
    /// macOS 26 window corners (concentric with the page card: 10 pt inset + 6 pt card radius).
    static let windowRadius: CGFloat = 16

    struct Layer {
        enum Shadow { case window, panel, none }
        var image: NSImage
        /// Canvas points, origin bottom-left.
        var frame: NSRect
        var radius: CGFloat = MarketingStudio.windowRadius
        /// A dark window gets a light inner edge, as macOS draws one.
        var dark = false
        /// Traffic light centres in the layer's own points (origin bottom-left), painted in colour.
        var lights: [NSPoint] = []
        var shadow: Shadow = .window
    }

    /// A canvas that holds `content` (points) with the standard margins.
    static func canvas(around content: NSSize) -> (size: NSSize, origin: NSPoint) {
        (NSSize(width: content.width + margin.left + margin.right, height: content.height + margin.top + margin.bottom),
         NSPoint(x: margin.left, y: margin.bottom))
    }

    static func render(canvas: NSSize, dark: Bool, layers: [Layer]) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The size in points first: the context takes its 2× scale from it.
        rep.size = canvas
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        backdrop(NSRect(origin: .zero, size: canvas), dark: dark, cg)
        for l in layers { draw(l, cg) }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func write(_ rep: NSBitmapImageRep?, to url: URL) -> Bool {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: The desktop

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    /// Dawn (light shots) or dusk (dark ones): a diagonal wash in the icon's spectrum, softened by a few wide glows,
    /// like a macOS wallpaper. Code-drawn, so it renders the same on every run.
    static func backdrop(_ r: NSRect, dark: Bool, _ cg: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let base = dark ? [rgb(0x1E1A3D), rgb(0x40295C), rgb(0x7C3F5E)] : [rgb(0xB3C0F6), rgb(0xDCC0EA), rgb(0xF7D3BD)]
        if let g = CGGradient(colorsSpace: space, colors: base.map(\.cgColor) as CFArray, locations: [0, 0.52, 1]) {
            cg.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // Wide glows with a long, soft falloff (no edge to see).
        let glows: [(x: CGFloat, y: CGFloat, radius: CGFloat, color: NSColor, alpha: CGFloat)] = dark
            ? [(0.10, 0.95, 0.70, rgb(0x5458C8), 0.50), (0.95, 0.05, 0.65, rgb(0xD0706A), 0.38), (0.60, 0.50, 0.50, rgb(0x96449A), 0.25)]
            : [(0.08, 0.98, 0.70, rgb(0xFFFFFF), 0.50), (0.96, 0.02, 0.62, rgb(0xFFC7A2), 0.60), (0.55, 0.45, 0.55, rgb(0xEBC6F4), 0.40)]
        let span = max(r.width, r.height)
        let falloff: [CGFloat] = [1, 0.72, 0.42, 0.2, 0.07, 0]
        let locations: [CGFloat] = [0, 0.2, 0.42, 0.62, 0.82, 1]
        for g in glows {
            let colors = falloff.map { g.color.withAlphaComponent(g.alpha * $0).cgColor } as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { continue }
            let c = CGPoint(x: r.minX + g.x * r.width, y: r.minY + g.y * r.height)
            cg.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: g.radius * span, options: [])
        }
    }

    // MARK: Windows

    static func path(_ rect: NSRect, radius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    private static func draw(_ l: Layer, _ cg: CGContext) {
        let shape = path(l.frame, radius: l.radius)
        // Shadows are in the context's base (pixel) space.
        func shadow(_ y: CGFloat, _ blur: CGFloat, _ alpha: CGFloat) {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -y * scale), blur: blur * scale, color: NSColor.black.withAlphaComponent(alpha).cgColor)
            cg.addPath(shape)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            cg.restoreGState()
        }
        switch l.shadow {
        case .window:
            shadow(30, 64, l.dark ? 0.42 : 0.30)
            shadow(3, 8, 0.20)
        case .panel:
            shadow(18, 40, 0.30)
            shadow(2, 5, 0.18)
        case .none:
            break
        }
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        l.image.draw(in: l.frame)
        for (p, colors) in zip(l.lights, trafficLights) {
            let c = NSPoint(x: l.frame.minX + p.x, y: l.frame.minY + p.y)
            let dot = NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            cg.setFillColor(colors.fill.cgColor)
            cg.fillEllipse(in: dot)
            cg.setStrokeColor(colors.edge.cgColor)
            cg.setLineWidth(0.5)
            cg.strokeEllipse(in: dot.insetBy(dx: 0.25, dy: 0.25))
        }
        cg.restoreGState()
        // The window's edge: a dark hairline outside, and in dark windows a faint light one inside.
        cg.saveGState()
        cg.addPath(shape)
        cg.setStrokeColor(NSColor.black.withAlphaComponent(l.dark ? 0.55 : 0.16).cgColor)
        cg.setLineWidth(1)
        cg.strokePath()
        if l.dark {
            cg.addPath(path(l.frame.insetBy(dx: 0.75, dy: 0.75), radius: l.radius - 0.75))
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            cg.setLineWidth(0.5)
            cg.strokePath()
        }
        cg.restoreGState()
    }

    /// Close, minimise, zoom in an active window.
    private static let trafficLights: [(fill: NSColor, edge: NSColor)] = [
        (rgb(0xFF5F57), rgb(0xE0443E)), (rgb(0xFEBC2E), rgb(0xDEA123)), (rgb(0x28C840), rgb(0x1AAB29)),
    ]

    /// The demo call's artwork: a 128 px green tile with a white camera.
    static func callIcon() -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGradient(colors: [rgb(0x38A57C), rgb(0x23785A)])?.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), angle: -90)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 26, y: 42, width: 52, height: 44), xRadius: 9, yRadius: 9).fill()
        let lens = NSBezierPath()
        lens.move(to: NSPoint(x: 84, y: 56)); lens.line(to: NSPoint(x: 104, y: 44)); lens.line(to: NSPoint(x: 104, y: 84)); lens.line(to: NSPoint(x: 84, y: 72))
        lens.close()
        lens.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Generated cover art for the demo radio (a 512 px gradient sleeve with a sun and a horizon).
    static func coverArt() -> Data {
        let n = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(x: 0, y: 0, width: n, height: n)
        NSGradient(colors: [rgb(0x2B1E5C), rgb(0xB44E7A), rgb(0xF6A76A)])?.draw(in: r, angle: 90)
        rgb(0xFFE3B0, 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 156, y: 150, width: 200, height: 200)).fill()
        for (i, c) in [rgb(0x3A2C6E, 0.85), rgb(0x22184A, 0.92), rgb(0x150F33)].enumerated() {
            let p = NSBezierPath()
            let y = CGFloat(190 - i * 55)
            p.move(to: NSPoint(x: 0, y: 0))
            p.line(to: NSPoint(x: 0, y: y))
            for x in stride(from: 0, through: n, by: 32) {
                p.line(to: NSPoint(x: CGFloat(x), y: y + 26 * sin(CGFloat(x) / CGFloat(70 + i * 30) + CGFloat(i))))
            }
            p.line(to: NSPoint(x: n, y: 0))
            p.close()
            c.setFill()
            p.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Demo pages

/// Pages for the shots no public site can stand in for without an account or a camera: a call, a short film, a radio
/// and a shared folder. Served on 127.0.0.1 only (one fixed port) and reached as *.aircbrowser.com through the engine's
/// host rules (scripts/marketing-shots.sh), so no URL reads 127.0.0.1 and no request leaves the Mac. The call is
/// illustrated tiles, a canvas self-view and silent audio: nothing asks for a camera or a microphone.
final class MarketingServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.marketing.server")
    private let cover = MarketingStudio.coverArt()
    private let callIcon = MarketingStudio.callIcon()
    private let silence = MarketingServer.silentWAV(seconds: 8)
    /// Bytes per second for the one slow download after its first part (it runs while the shots are taken).
    var slowRate = 900_000

    struct File { var name: String; var size: Int; var slowAfter: Int? }
    /// Pages and downloads of parts in other files (MarketingAI.swift), by path; set before their pages load.
    static var extraPages: [String: String] = [:]
    static var extraFiles: [String: (type: String, data: Data)] = [:]
    static let files: [File] = [
        File(name: "Lisbon itinerary.pdf", size: 2_412_000),
        File(name: "Brand guidelines.pdf", size: 8_730_000),
        File(name: "Q4 launch deck.key", size: 14_180_000),
        File(name: "Offsite photos.zip", size: 23_600_000),
        File(name: "Launch film (4K).mov", size: 96_400_000, slowAfter: 33_000_000),
    ]

    init?(port: UInt16) {
        let params = NWParameters.tcp
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
    }

    func start(_ ready: @escaping (Bool) -> Void) {
        var answered = false
        listener.stateUpdateHandler = { state in
            let ok: Bool
            switch state {
            case .ready: ok = true
            case .failed, .cancelled: ok = false
            default: return
            }
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                ready(ok)
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return c.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return complete || error != nil || buffer.count > 65536 ? c.cancel() : self.receive(c, buffer)
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.split(separator: "\r\n").map(String.init)
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?").first ?? "/")
            let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            self.respond(c, path: path.removingPercentEncoding ?? path, range: range)
        }
    }

    private func respond(_ c: NWConnection, path: String, range: String?) {
        let html = ["Content-Type": "text/html; charset=utf-8"]
        switch path {
        // Artwork goes in as data: URLs: the app draws the tray's artwork itself, outside the engine's host rules.
        case "/weekly-sync": send(c, "200 OK", html, Data(Self.callPage.replacingOccurrences(of: "{icon}", with: callIcon.base64EncodedString()).utf8))
        case "/golden-hour": send(c, "200 OK", html, Data(Self.filmPage.replacingOccurrences(of: "{cover}", with: cover.base64EncodedString()).utf8))
        case "/radio": send(c, "200 OK", html, Data(Self.radioPage.replacingOccurrences(of: "{cover}", with: cover.base64EncodedString()).utf8))
        case "/shared": send(c, "200 OK", html, Data(Self.filesPage.utf8))
        case "/journal/a-quieter-web": send(c, "200 OK", html, Data(Self.fieldnotesPage.utf8))
        case "/lisbon": send(c, "200 OK", html, Data(SnapshotRunner.mkCapturePage.utf8))   // Capture's shot (MarketingCapture.swift)
        case "/cover.png": send(c, "200 OK", ["Content-Type": "image/png"], cover)
        case "/silence.wav": sendRange(c, silence, type: "audio/wav", range: range)
        default:
            if let page = Self.extraPages[path] { return send(c, "200 OK", html, Data(page.utf8)) }
            if let f = Self.extraFiles[path] {
                let name = (path as NSString).lastPathComponent
                return send(c, "200 OK", ["Content-Type": f.type, "Content-Disposition": "attachment; filename=\"\(name)\""], f.data)
            }
            if path.hasPrefix("/files/"), let f = Self.files.first(where: { $0.name == String(path.dropFirst(7)) }) {
                return stream(c, f)
            }
            // Library › Media's pictures and films (MarketingLibrary.swift).
            if path.hasPrefix("/media/"), let f = SnapshotRunner.mkLibraryMedia[String(path.dropFirst(7))] {
                return send(c, "200 OK", ["Content-Type": f.type, "Content-Disposition": "attachment; filename=\"\(path.dropFirst(7))\""], f.data)
            }
            send(c, "404 Not Found", ["Content-Type": "text/plain"], Data("not found".utf8))
        }
    }

    private func send(_ c: NWConnection, _ status: String, _ headers: [String: String], _ body: Data) {
        var h = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { h += "\(k): \(v)\r\n" }
        c.send(content: Data((h + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func sendRange(_ c: NWConnection, _ data: Data, type: String, range: String?) {
        guard let r = range, r.hasPrefix("bytes=") else { return send(c, "200 OK", ["Content-Type": type, "Accept-Ranges": "bytes"], data) }
        let bounds = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let from = min(bounds.first.flatMap { $0 } ?? 0, max(0, data.count - 1))
        let to = min(bounds.count > 1 ? (bounds[1] ?? data.count - 1) : data.count - 1, data.count - 1)
        guard from <= to else { return send(c, "416 Range Not Satisfiable", ["Content-Range": "bytes */\(data.count)"], Data()) }
        send(c, "206 Partial Content", ["Content-Type": type, "Accept-Ranges": "bytes", "Content-Range": "bytes \(from)-\(to)/\(data.count)"],
             data.subdata(in: from..<(to + 1)))
    }

    /// A file of zeros under its real name: quickly, or quickly up to `slowAfter` and then at `slowRate`.
    private func stream(_ c: NWConnection, _ f: File) {
        let type: String = switch (f.name as NSString).pathExtension {
        case "pdf": "application/pdf"
        case "zip": "application/zip"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
        let encoded = f.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? f.name
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(f.size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(f.name)\"; filename*=UTF-8''\(encoded)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        var sent = 0
        let chunk = 262_144
        func next() {
            guard sent < f.size else { return c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
            let slow = f.slowAfter.map { sent >= $0 } ?? false
            let n = min(slow ? max(16_384, slowRate / 10) : chunk, f.size - sent)
            sent += n
            c.send(content: Data(count: n), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { return c.cancel() }
                if slow { self.queue.asyncAfter(deadline: .now() + 0.1, execute: next) } else { self.queue.async(execute: next) }
            })
        }
        queue.async(execute: next)
    }

    /// 16 kHz mono 16-bit zeros: a playing media session without a sound on the Mac's speakers.
    private static func silentWAV(seconds: Int) -> Data {
        let samples = 16_000 * seconds
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        d.append(Data(count: samples * 2))
        return d
    }

    /// A small square favicon in `color` with a white glyph (inline, so every demo site has its own icon).
    private static func icon(_ color: String, _ glyph: String) -> String {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='8' fill='\(color)'/>\(glyph)</svg>"
        return "<link rel='icon' href='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>"
    }

    /// Fieldnotes reading page for the toolbar and Copy URL shots.
    static let fieldnotesPage = """
    <!doctype html><meta name="theme-color" content="#f7f4ed"><title>A quieter web · Fieldnotes</title>
    <style>body{margin:0;background:#f7f4ed;color:#273f34;font:18px -apple-system}nav{padding:30px 54px;border-bottom:1px solid #deded2;display:flex;justify-content:space-between}main{max-width:710px;margin:70px auto}small{letter-spacing:3px;font-size:11px;color:#65816a}h1{font:64px Georgia;letter-spacing:-2px;line-height:1.1;margin:24px 0}p{line-height:1.8;color:#5b6a60}blockquote{font:28px Georgia;line-height:1.5;border-left:2px solid #99ae91;padding:12px 28px;margin:38px 0}.tag{font-size:12px;color:#73846d}</style>
    <nav><b>Fieldnotes</b><span class=tag>IDEAS FOR EVERYDAY LIFE</span></nav><main><small>DESIGN / 6 MIN READ</small><h1>A quieter corner<br>of the web.</h1><p>Space to think. Room to explore. A few familiar tools, right where you expect them.</p><blockquote>The best tools leave a little more room for what matters.</blockquote><p>Keep the whole address in view, follow a new idea, and find your way back. Sometimes a small change makes everything feel more familiar.</p></main>
    """

    // MARK: The call: illustrated people on canvases, silent audio. Never getUserMedia.

    /// `?pip=document`: like Meet, the page opens its own Document PiP from the Media Session's enterpictureinpicture
    /// action and moves the call into it. Otherwise the host's picture in picture takes the speaker's video.
    static let callPage = """
    <!doctype html><meta charset="utf-8"><title>Weekly design sync</title>
    \(icon("#2F8F6B", "<path d='M8 11h11a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2v-6a2 2 0 0 1 2-2zm14 4 5-3v8l-5-3z' fill='white'/>"))
    <style>
    *{box-sizing:border-box}html,body{margin:0;height:100%;background:#16181d;color:#f4f5f7;font:14px -apple-system,system-ui;overflow:hidden}
    #grid{position:absolute;inset:12px 12px 72px;display:grid;grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr;gap:10px}
    .t{position:relative;border-radius:14px;overflow:hidden;display:flex;align-items:center;justify-content:center}
    .t svg{width:46%;max-width:150px;height:auto}.t video,.t canvas{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
    .t .n{position:absolute;left:10px;bottom:9px;padding:3px 8px;border-radius:7px;background:rgba(0,0,0,.35);font-weight:500;font-size:12px}
    .t.talk{box-shadow:inset 0 0 0 3px #7dd3a8}
    #bar{position:absolute;left:0;right:0;bottom:14px;display:flex;justify-content:center;gap:12px}
    #bar b{width:44px;height:44px;border-radius:22px;background:#2b2f37;display:flex;align-items:center;justify-content:center}
    #bar b.end{background:#e5484d;width:58px}#bar svg{width:20px;height:20px}
    #top{position:absolute;left:18px;bottom:26px;font-weight:600;font-size:13px;color:#c9ccd3}
    @media (max-width:560px){#bar,#top{display:none}#grid{inset:6px;gap:6px}.t{border-radius:10px}.t .n{font-size:10px;left:6px;bottom:5px}}
    </style>
    <div id="grid">
      <div class="t talk"><video id="v" autoplay muted playsinline></video><span class="n">Maya</span></div>
      <div class="t" style="background:linear-gradient(135deg,#a9c8f5,#7d8fe0)">\(person(skin: "#c98e66", hair: "#1e1b1a", shirt: "#e8b04b"))<span class="n">Jonas</span></div>
      <div class="t" style="background:linear-gradient(135deg,#b9e3c9,#6dbb9b)">\(person(skin: "#8d5a3b", hair: "#120d0b", shirt: "#c4553f"))<span class="n">Priya</span></div>
      <div class="t"><canvas id="me" width="480" height="300"></canvas><span class="n">You</span></div>
    </div>
    <div id="top">Weekly design sync · 10:02</div>
    <div id="bar">
      <b><svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg></b>
      <b><svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2"><rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/></svg></b>
      <b><svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/></svg></b>
      <b class="end"><svg viewBox="0 0 24 24" fill="white"><path d="M12 9c-3.2 0-6.2.9-8.6 2.6-.6.4-.8 1.2-.4 1.9l1.3 2c.4.6 1.1.8 1.7.5l2.6-1.2c.5-.2.8-.8.7-1.3l-.3-1.6c1.9-.6 4.1-.6 6 0l-.3 1.6c-.1.5.2 1.1.7 1.3l2.6 1.2c.6.3 1.3.1 1.7-.5l1.3-2c.4-.7.2-1.5-.4-1.9C18.2 9.9 15.2 9 12 9z"/></svg></b>
    </div>
    <audio id="r" src="/silence.wav" loop autoplay></audio>
    <script>
    var mic = true, cam = true, ended = false, pipWin = null, f = 0, log = [];
    var stage = document.createElement('canvas'); stage.width = 640; stage.height = 360;
    var sx = stage.getContext('2d'), mx = document.getElementById('me').getContext('2d');
    // An illustrated person: shoulders, head and hair on a soft gradient, breathing a little.
    function person(x, w, h, bg, skin, hair, shirt, t){
      var g = x.createLinearGradient(0, 0, w, h); g.addColorStop(0, bg[0]); g.addColorStop(1, bg[1]); x.fillStyle = g; x.fillRect(0, 0, w, h);
      var cx = w / 2, b = Math.sin(t / 24) * 2.5, r = h * .17;
      x.fillStyle = 'rgba(255,255,255,.16)'; x.beginPath(); x.arc(cx, h * .5, h * .42, 0, 7); x.fill();
      x.fillStyle = shirt; x.beginPath(); x.ellipse(cx, h * 1.02, w * .26, h * .34, 0, Math.PI, 2 * Math.PI); x.fill();
      x.fillStyle = skin; x.beginPath(); x.arc(cx, h * .45 + b, r, 0, 7); x.fill();
      x.fillStyle = hair; x.beginPath(); x.arc(cx, h * .42 + b, r * 1.04, Math.PI * 1.02, Math.PI * 1.98); x.fill();
    }
    function frame(){
      person(sx, 640, 360, ['#f6c7a8', '#e98f8f'], '#f2c4a0', '#3b2a24', '#2f5d8a', f);
      // Speaking: a soft pulse round the speaker.
      sx.strokeStyle = 'rgba(125,211,168,' + (.35 + .25 * Math.sin(f / 5)) + ')'; sx.lineWidth = 6;
      sx.beginPath(); sx.arc(320, 162 + Math.sin(f / 24) * 2.5, 78 + 4 * Math.sin(f / 5), 0, 7); sx.stroke();
      person(mx, 480, 300, ['#3d4a6b', '#6b4a6e'], '#e9b48f', '#4b3328', '#5a7bd8', f + 40); f++;
    }
    setInterval(frame, 50); frame();
    var stream = stage.captureStream(20), v = document.getElementById('v'), a = new RTCPeerConnection(), b = new RTCPeerConnection();
    a.onicecandidate = function(e){ e.candidate && b.addIceCandidate(e.candidate); };
    b.onicecandidate = function(e){ e.candidate && a.addIceCandidate(e.candidate); };
    b.ontrack = function(e){ v.srcObject = e.streams[0]; v.play().catch(function(){}); };
    stream.getTracks().forEach(function(t){ a.addTrack(t, stream); });
    (async function(){ await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
      await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription); })().catch(function(e){ log.push('rtc:' + e.name); });
    var ms = navigator.mediaSession, grid = document.getElementById('grid');
    function report(){ try { ms.setMicrophoneActive(mic); ms.setCameraActive(cam); } catch (e) {} }
    ms.metadata = new MediaMetadata({title: 'Weekly design sync', artwork: [{src: 'data:image/png;base64,{icon}', sizes: '128x128', type: 'image/png'}]});
    ms.setActionHandler('togglemicrophone', function(){ mic = !mic; log.push('mic:' + mic); report(); });
    ms.setActionHandler('togglecamera', function(){ cam = !cam; log.push('cam:' + cam); report(); });
    ms.setActionHandler('hangup', function(){ hangup(); });
    if (new URLSearchParams(location.search).get('pip') === 'document') ms.setActionHandler('enterpictureinpicture', async function(){
      try {
        pipWin = await documentPictureInPicture.requestWindow({width: 640, height: 400, preferInitialWindowPlacement: true});
        pipWin.document.head.append(document.querySelector('style').cloneNode(true));
        pipWin.document.body.style.cssText = 'margin:0;background:#16181d;color:#f4f5f7;font:14px -apple-system,system-ui;overflow:hidden';
        var moved = [grid, document.getElementById('top'), document.getElementById('bar')];
        moved.forEach(function(node){ pipWin.document.body.append(node); }); log.push('document-enter');
        pipWin.addEventListener('pagehide', function(){ moved.forEach(function(node){ document.body.append(node); }); }, {once: true});
      } catch (e) { log.push('pip-error:' + e.name); }
    });
    function hangup(){ ended = true; stream.getTracks().forEach(function(t){ t.stop(); }); a.close(); b.close(); document.getElementById('r').pause();
      ['togglemicrophone', 'togglecamera', 'hangup', 'enterpictureinpicture'].forEach(function(k){ try { ms.setActionHandler(k, null); } catch (e) {} }); }
    function state(){ return {log: log, doc: !!pipWin && !pipWin.closed, playing: !v.paused && v.readyState > 2, ended: ended,
      secure: window.isSecureContext, documentPiP: typeof documentPictureInPicture}; }
    document.getElementById('r').play().catch(function(){});
    report();
    </script>
    """

    private static func person(skin: String, hair: String, shirt: String) -> String {
        "<svg viewBox='0 0 120 120'><circle cx='60' cy='60' r='58' fill='rgba(255,255,255,.22)'/>"
            + "<path d='M18 112c4-24 22-36 42-36s38 12 42 36' fill='\(shirt)'/>"
            + "<circle cx='60' cy='52' r='24' fill='\(skin)'/>"
            + "<path d='M35 50c0-17 11-27 25-27s25 10 25 27c-4-8-12-13-25-13s-21 5-25 13z' fill='\(hair)'/></svg>"
    }

    // MARK: A short film: a canvas animation recorded into a clip (no file, no devices), with a full Media Session

    static let filmPage = """
    <!doctype html><meta charset="utf-8"><title>Golden Hour – a short film</title>
    \(icon("#E8664D", "<path d='M12 10l11 6-11 6z' fill='white'/>"))
    <style>html,body{margin:0;background:#0f0f12;color:#eee;font:15px -apple-system,system-ui}
    main{max-width:1100px;margin:40px auto;padding:0 32px}video{width:100%;aspect-ratio:16/9;border-radius:12px;display:block;background:#000}
    h1{font-size:28px;margin:22px 0 6px;font-weight:650}p{color:#9a9aa3;margin:0}</style>
    <main><video id="v" playsinline loop></video><h1>Golden Hour</h1><p>A short film · 4 min · Lisbon, March</p></main>
    <canvas id="c" width="1280" height="720" hidden></canvas>
    <script>
    var c = document.getElementById('c'), x = c.getContext('2d'), t = 0, v = document.getElementById('v'), ms = navigator.mediaSession, src;
    var pos = 61, posAt = performance.now();
    function ridge(base, amp, freq, phase, color){ x.fillStyle = color; x.beginPath(); x.moveTo(0, 720);
      for (var i = 0; i <= 1280; i += 16) x.lineTo(i, base + amp * Math.sin(i / freq + phase) + amp * .5 * Math.sin(i / (freq * .37) + phase * 1.7));
      x.lineTo(1280, 720); x.fill(); }
    function frame(){
      var g = x.createLinearGradient(0, 0, 0, 720); g.addColorStop(0, '#2d2a6e'); g.addColorStop(.45, '#c55a7a'); g.addColorStop(.75, '#f5a26b'); g.addColorStop(1, '#ffd9a0');
      x.fillStyle = g; x.fillRect(0, 0, 1280, 720);
      var sy = 430 - 6 * Math.sin(t / 40); var s = x.createRadialGradient(820, sy, 10, 820, sy, 230);
      s.addColorStop(0, 'rgba(255,240,200,1)'); s.addColorStop(.35, 'rgba(255,214,150,.75)'); s.addColorStop(1, 'rgba(255,190,140,0)');
      x.fillStyle = s; x.fillRect(0, 0, 1280, 720);
      x.fillStyle = 'rgba(255,255,255,.18)'; for (var k = 0; k < 4; k++) { var cx = (k * 380 + t * 3) % 1500 - 160; x.beginPath(); x.ellipse(cx, 140 + k * 46, 150, 18, 0, 0, 7); x.fill(); }
      ridge(470, 38, 160, t / 60, '#5b3a6e'); ridge(530, 30, 120, t / 40 + 2, '#3e2858'); ridge(600, 22, 90, t / 28 + 4, '#241a3d'); ridge(660, 12, 60, t / 18 + 1, '#140f26');
      t++; }
    function now(){ return ms.playbackState === 'playing' ? Math.min(252, pos + (performance.now() - posAt) / 1000) : pos; }
    function at(p){ pos = Math.max(0, Math.min(252, p)); posAt = performance.now(); ms.setPositionState({duration: 252, playbackRate: 1, position: pos}); }
    // Four seconds of the animation and silent WebAudio, recorded and looped; the session says the film is 4:12.
    async function record(){
      var timer = setInterval(frame, 40); frame();
      var ac = new AudioContext(), o = ac.createOscillator(), gain = ac.createGain(), d = ac.createMediaStreamDestination();
      gain.gain.value = 0; o.connect(gain).connect(d); o.start();
      var st = c.captureStream(25); st.addTrack(d.stream.getAudioTracks()[0]);
      var r = new MediaRecorder(st, {mimeType: 'video/webm;codecs=vp8,opus', videoBitsPerSecond: 8000000}), chunks = [];
      r.ondataavailable = function(e){ chunks.push(e.data); }; r.start();
      await new Promise(function(f){ setTimeout(f, 4000); }); await new Promise(function(f){ r.onstop = f; r.stop(); });
      clearInterval(timer); st.getTracks().forEach(function(k){ k.stop(); }); o.stop(); ac.close();
      src = URL.createObjectURL(new Blob(chunks, {type: 'video/webm'}));
    }
    window.start = async function(){ v.src = src; await v.play(); ms.playbackState = 'playing'; at(pos); document.title = 'Golden Hour – a short film'; return true; };
    ms.metadata = new MediaMetadata({title: 'Golden Hour', artist: 'A short film', album: 'Lisbon, March',
      artwork: [{src: 'data:image/png;base64,{cover}', sizes: '512x512', type: 'image/png'}]});
    ms.setActionHandler('play', function(){ var p = now(); v.play(); ms.playbackState = 'playing'; at(p); });
    ms.setActionHandler('pause', function(){ var p = now(); v.pause(); ms.playbackState = 'paused'; at(p); });
    ms.setActionHandler('seekto', function(e){ at(e.seekTime); });
    ms.setActionHandler('seekbackward', function(e){ at(now() - (e.seekOffset || 15)); });
    ms.setActionHandler('seekforward', function(e){ at(now() + (e.seekOffset || 15)); });
    ms.setActionHandler('previoustrack', function(){});
    ms.setActionHandler('nexttrack', function(){});
    record().then(function(){ document.title = 'Golden Hour (ready)'; }, function(e){ document.title = 'Golden Hour (error ' + e.name + ')'; });
    </script>
    """

    // MARK: A radio with a Media Session (silent audio)

    static let radioPage = """
    <!doctype html><meta charset="utf-8"><title>Slow Tide – Harbour Lights</title>
    \(icon("#B44E7A", "<circle cx='16' cy='16' r='7' fill='none' stroke='white' stroke-width='3'/><circle cx='16' cy='16' r='2' fill='white'/>"))
    <style>html,body{margin:0;height:100%;background:linear-gradient(160deg,#2b1e5c,#7a3b6b);color:#fff;font:15px -apple-system,system-ui}
    main{display:flex;gap:40px;align-items:center;justify-content:center;height:100%}img{width:300px;border-radius:16px;box-shadow:0 30px 60px rgba(0,0,0,.35)}
    h1{font-size:34px;margin:0 0 6px}p{margin:0;color:rgba(255,255,255,.7)}</style>
    <main><img src="/cover.png"><div><p>Now playing</p><h1>Slow Tide</h1><p>Harbour Lights · Night Swim</p></div></main>
    <audio id="a" src="/silence.wav" loop></audio>
    <script>
    var a = document.getElementById('a'), ms = navigator.mediaSession;
    ms.metadata = new MediaMetadata({title: 'Slow Tide', artist: 'Harbour Lights', album: 'Night Swim',
      artwork: [{src: 'data:image/png;base64,{cover}', sizes: '512x512', type: 'image/png'}]});
    ms.setActionHandler('play', function(){ a.play(); ms.playbackState = 'playing'; });
    ms.setActionHandler('pause', function(){ a.pause(); ms.playbackState = 'paused'; });
    ms.setActionHandler('nexttrack', function(){});
    ms.setActionHandler('previoustrack', function(){});
    a.play().then(function(){ ms.playbackState = 'playing'; }).catch(function(){});
    </script>
    """

    // MARK: A shared folder to download from

    static let filesPage: String = {
        let rows = files.map { f in
            "<a class='f' href='/files/\(f.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.name)' download>"
                + "<b>\(f.name)</b><span>\(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))</span></a>"
        }.joined()
        return """
        <!doctype html><meta charset="utf-8"><title>Launch assets – Shared folder</title>
        \(icon("#3B7BE0", "<path d='M7 11h7l2 2h9v10H7z' fill='white'/>"))
        <style>html,body{margin:0;background:#f6f7f9;color:#1b1d22;font:15px -apple-system,system-ui}
        main{max-width:760px;margin:56px auto;padding:0 28px}h1{font-size:26px;margin:0 0 4px}p{color:#6b7080;margin:0 0 26px}
        .f{display:flex;justify-content:space-between;padding:16px 18px;margin:0 0 10px;background:#fff;border-radius:12px;
        color:inherit;text-decoration:none;box-shadow:0 1px 2px rgba(0,0,0,.06)}.f span{color:#8a8f9c}</style>
        <main><h1>Launch assets</h1><p>Shared with the team · 5 items</p>\(rows)</main>
        """
    }()
}
#endif

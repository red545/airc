// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentspike --agent-demo`: the homepage's "For AI agents" loop (apps/marketing/public/motion/agents.webp,
/// scripts/make-agents-motion.mjs). A scripted run of the real app on a synthetic bakery site: the person is signed in
/// there in their own window; an MCP client named Claude connects (Airc asks once), opens the site in an agent window,
/// already signed in, reorders, sets the pickup time, adds a note and places the order. Each step's frame is the agent
/// window's real screenshot (the MCP screenshot tool) beside a drawn conversation that lists the tool calls made.
/// Frames and their timing go to <snapshot dir>/agents-demo/ (capture.json). Synthetic data only.
final class AgentsDemo {
    let spike: AgentSpike
    var runner: SnapshotRunner { spike.runner }
    var frames: [[String: Any]] = []
    var chat: [Line] = []
    /// agents-demo/ for the homepage loop, agents-<mode>/ for the social studio's sequences (AgentsDemoClips.swift).
    var dir: URL { runner.dir.appendingPathComponent(AgentsDemo.mode.map { $0 == "loop" ? "agents-demo" : "agents-\($0)" } ?? "agents-demo") }
    let size = CGSize(width: 1920, height: 1200)

    struct Line { enum Kind { case person, tool, claude }; let kind: Kind; let text: String; var detail: String? = nil }

    init(spike: AgentSpike) { self.spike = spike }

    // Fixed colours: the frames look the same whatever the Mac's appearance.
    static let ink = NSColor(srgbRed: 0.17, green: 0.13, blue: 0.10, alpha: 1)
    static let ink2 = NSColor(srgbRed: 0.45, green: 0.41, blue: 0.37, alpha: 1)
    static let ink3 = NSColor(srgbRed: 0.65, green: 0.61, blue: 0.57, alpha: 1)

    static let site: [String: String] = [
        "/bakery/account": """
        <!doctype html><title>Pastelaria Aurora</title>\(style)<header><b>Pastelaria Aurora</b><span>Signed in as Ada Example</span></header>
        <main><h1>Welcome back, Ada</h1><p class="muted">Your usual, from last Tuesday</p>
        <div class="card"><div>2 × Pastel de nata</div><div>1 × Galão</div><div class="sum">€ 4.90</div></div>
        <a class="btn" href="/bakery/order">Order again</a></main>
        """,
        "/bakery/order": """
        <!doctype html><title>Your order · Pastelaria Aurora</title>\(style)<header><b>Pastelaria Aurora</b><span>Signed in as Ada Example</span></header>
        <main><h1>Your order</h1><form method="post" action="/bakery/done">
        <div class="card"><div>2 × Pastel de nata</div><div>1 × Galão</div><div class="sum">€ 4.90</div></div>
        <label>Pickup time<input id="time" name="time" placeholder="e.g. 8:45"></label>
        <label>Note for the bakery<input id="note" name="note" placeholder="Optional"></label>
        <button class="btn" id="place">Place order</button></form></main>
        """,
        "/bakery/done": """
        <!doctype html><title>Order placed · Pastelaria Aurora</title>\(style)<header><b>Pastelaria Aurora</b><span>Signed in as Ada Example</span></header>
        <main><div class="ok">✓</div><h1>Order #4821 is in</h1><p class="muted">Pickup at 9:30 · Pastelaria Aurora, Rua das Flores 12</p>
        <div class="card"><div>2 × Pastel de nata</div><div>1 × Galão</div><div class="sum">€ 4.90</div></div></main>
        """,
    ]

    static let style = """
    <style>body{margin:0;font:18px/1.45 -apple-system,system-ui,sans-serif;background:#fbf6ef;color:#2b2118}
    header{display:flex;justify-content:space-between;align-items:center;padding:22px 48px;background:#fff;border-bottom:1px solid #eadfce}
    header b{font-size:20px;color:#9a4a1c}header span{color:#7b6a58;font-size:15px}
    main{max-width:620px;margin:44px auto;padding:0 24px}h1{font-size:34px;margin:0 0 6px}.muted{color:#7b6a58;margin:0 0 22px}
    .card{background:#fff;border:1px solid #eadfce;border-radius:14px;padding:18px 22px;margin:0 0 22px}.card div{padding:4px 0}
    .sum{border-top:1px solid #eadfce;margin-top:8px;padding-top:10px!important;font-weight:600}
    label{display:block;margin:0 0 16px;color:#5a4a3a;font-size:15px}input{display:block;width:100%;box-sizing:border-box;margin-top:6px;
    font:18px -apple-system,sans-serif;padding:11px 14px;border:1px solid #d9c9b4;border-radius:10px;background:#fff}
    .btn{display:inline-block;border:0;border-radius:12px;background:#c2551f;color:#fff;font:600 18px -apple-system,sans-serif;
    padding:13px 26px;text-decoration:none;cursor:pointer}.ok{width:56px;height:56px;border-radius:28px;background:#2f9e62;color:#fff;
    font-size:30px;display:flex;align-items:center;justify-content:center;margin-bottom:16px}</style>
    """

    /// The bakery's pages for the spike's fixture server (the person's sign-in cookie decides "Signed in").
    func page(_ r: LocalPageServer.Request) -> LocalPageServer.Page? {
        if r.method == "POST", r.path == "/bakery/done" { return LocalPageServer.Page(status: "303 See Other", headers: ["Location": "/bakery/done"], body: "") }
        guard r.method == "GET", let body = Self.site[r.path] else { return nil }
        // Signed in only with the session the person's sign-in set (the fixture site's cookie).
        if (r.headers["cookie"] ?? "").contains("sid=\(spike.sessionSecret)") { return LocalPageServer.Page(body: body) }
        return LocalPageServer.Page(body: body.replacingOccurrences(of: "Signed in as Ada Example", with: "Sign in")
            .replacingOccurrences(of: "Welcome back, Ada", with: "Welcome"))
    }

    // MARK: The run

    func run(_ done: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = spike.base
        let defaultName = spike.app.store.defaultProfile.name
        let claude = spike.helper(defaultName, client: "Claude")
        spike.extra.append(claude)
        chat = [Line(kind: .person, text: "Order my usual from Pastelaria Aurora for pickup at 9:30, with less sugar.")]
        var shot: CGImage?
        func call(_ tool: String, _ args: [String: Any], show: String? = nil, detail: String? = nil, _ then: @escaping ([String: Any]) -> Void) {
            claude.call(tool, args) { r, _ in
                if let show { self.chat.append(Line(kind: .tool, text: show, detail: detail)) }
                then(r)
            }
        }
        func snap(hold: Double, _ then: @escaping () -> Void) {
            claude.call("screenshot") { r, _ in
                shot = SpikeMCPClient.image(r) ?? shot
                self.frame(shot, hold: hold)
                then()
            }
        }
        func click(_ text: String, _ then: @escaping () -> Void) {
            claude.call("find_element", ["text": text]) { r, _ in
                let line = SpikeMCPClient.text(r).components(separatedBy: "\n").first { $0.hasPrefix("[") } ?? "[]"
                let m = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [[String: Any]])?.first
                let x = m?["x"] as? Int ?? 0, y = m?["y"] as? Int ?? 0
                call("left_click", ["coordinate": [x, y]], show: "left_click", detail: "“\(text)” at \(x), \(y)") { _ in then() }
            }
        }
        // The first connection: Airc asks once.
        spike.connect(claude, answer: .allow) { ok, _ in
            self.spike.check(ok, "demo: Claude connects after Allow")
            call("open_window", ["url": "\(base)/bakery/account"], show: "open_window", detail: "pastelaria-aurora · your profile") { _ in
                snap(hold: 1.4) {
                    call("read_page", [:], show: "read_page", detail: "“Signed in as Ada Example”") { r in
                        self.spike.check(SpikeMCPClient.text(r).contains("Signed in as Ada Example"), "demo: the agent window is already signed in")
                        snap(hold: 1.6) {
                            click("Order again") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    snap(hold: 1.3) {
                                        click("Pickup time") {
                                            call("type", ["text": "9:30"], show: "type", detail: "“9:30”") { _ in
                                                snap(hold: 1.0) {
                                                    click("Note for the bakery") {
                                                        call("type", ["text": "Less sugar, please"], show: "type", detail: "“Less sugar, please”") { _ in
                                                            snap(hold: 1.3) {
                                                                click("Place order") {
                                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                                                        snap(hold: 0.8) {
                                                                            claude.call("read_page") { r, _ in
                                                                                let placed = SpikeMCPClient.text(r).contains("Order #4821")
                                                                                self.spike.check(placed, "demo: the order is placed")
                                                                                self.chat.append(Line(kind: .claude, text: "Done. Order #4821: 2 pastéis de nata and a galão, pickup at 9:30, with your note."))
                                                                                self.frame(shot, hold: 3.2)
                                                                                self.write()
                                                                                claude.stop()
                                                                                done()
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // The approval frame, while Airc asks.
        spike.poll({ AgentCenter.shared.approvals.shown != nil }, timeout: 6) { asked in
            guard asked, let panel = AgentCenter.shared.approvals.shown, let rep = panel.picture(), let image = rep.cgImage else { return }
            self.frame(nil, hold: 1.8, overlay: image)
        }
    }

    func write() {
        let json: [String: Any] = ["frames": frames, "size": [Int(size.width), Int(size.height)]]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("capture.json"))
        }
        runner.note("demo: \(frames.count) frames, \(frames.reduce(0.0) { $0 + ($1["hold"] as? Double ?? 0) }) s in \(dir.lastPathComponent)/")
    }

    // MARK: Drawing a frame

    func frame(_ page: CGImage?, hold: Double, overlay: CGImage? = nil) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let W = size.width, H = size.height
        // Background: warm paper with a soft peach glow.
        NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.95, blue: 0.91, alpha: 1), NSColor(srgbRed: 0.96, green: 0.93, blue: 0.97, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)
        // The conversation (left).
        let chatRect = NSRect(x: 48, y: 48, width: 620, height: H - 96)
        card(chatRect, radius: 26)
        var y = chatRect.maxY - 40
        text("Claude", at: NSPoint(x: chatRect.minX + 32, y: y - 30), size: 30, weight: .semibold, color: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        text("using Airc", at: NSPoint(x: chatRect.minX + 152, y: y - 27), size: 22, weight: .regular, color: Self.ink2)
        y -= 70
        for line in chat {
            switch line.kind {
            case .person:
                let h = bubble(line.text, top: y, x: chatRect.minX + 120, width: chatRect.width - 152,
                               fill: NSColor(srgbRed: 0.93, green: 0.90, blue: 0.86, alpha: 1), size: 25)
                y -= h + 22
            case .tool:
                let row = NSRect(x: chatRect.minX + 32, y: y - 46, width: chatRect.width - 64, height: 46)
                let path = NSBezierPath(roundedRect: row, xRadius: 12, yRadius: 12)
                NSColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1).setFill(); path.fill()
                NSColor(srgbRed: 0.85, green: 0.47, blue: 0.25, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: row.minX + 16, y: row.midY - 6, width: 12, height: 12)).fill()
                text(line.text, at: NSPoint(x: row.minX + 40, y: row.minY + 10), size: 21, weight: .semibold, color: Self.ink, mono: true)
                if let d = line.detail {
                    let w = (line.text as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 21, weight: .semibold)]).width
                    text(d, at: NSPoint(x: row.minX + 52 + w, y: row.minY + 11), size: 20, weight: .regular, color: Self.ink2,
                         width: row.width - 68 - w)
                }
                y -= 58
            case .claude:
                let h = bubble(line.text, top: y - 6, x: chatRect.minX + 32, width: chatRect.width - 96, fill: .clear, size: 25)
                y -= h + 22
            }
        }
        // The agent window (right): the page as Airc pictured it for the agent.
        let winRect = NSRect(x: 716, y: 150, width: W - 716 - 48, height: (W - 716 - 48) * 800 / 1280 + 44)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        NSGraphicsContext.saveGraphicsState(); shadow.set(); card(winRect, radius: 18); NSGraphicsContext.restoreGraphicsState()
        card(winRect, radius: 18)
        let bar = NSRect(x: winRect.minX, y: winRect.maxY - 44, width: winRect.width, height: 44)
        text("✦  Agent window · Personal · never takes your screen", at: NSPoint(x: bar.minX + 22, y: bar.minY + 12), size: 19, weight: .medium,
             color: Self.ink2)
        let pageRect = NSRect(x: winRect.minX, y: winRect.minY, width: winRect.width, height: winRect.height - 44)
        if let page {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            clip.appendRoundedRect(pageRect, xRadius: 18, yRadius: 18)
            clip.append(NSBezierPath(rect: NSRect(x: pageRect.minX, y: pageRect.maxY - 20, width: pageRect.width, height: 20)))
            clip.addClip()
            ctx.cgContext.interpolationQuality = .high
            ctx.cgContext.draw(page, in: pageRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            text("Airc", at: NSPoint(x: pageRect.midX - 40, y: pageRect.midY - 16), size: 34, weight: .semibold, color: Self.ink3)
        }
        // The approval question, as Airc shows it (its own picture).
        if let overlay {
            let w = CGFloat(overlay.width), h = CGFloat(overlay.height)
            let scale = min(1, 760 / w) * (w < 500 ? 2 : 1)
            let r = NSRect(x: W - 48 - w * scale, y: H - 48 - h * scale, width: w * scale, height: h * scale)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16).addClip()
            ctx.cgContext.draw(overlay, in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = String(format: "frame-%03d.png", frames.count)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(name)) }
        frames.append(["file": name, "hold": hold])
    }

    private func card(_ r: NSRect, radius: CGFloat) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        p.lineWidth = 1; p.stroke()
    }

    private func attributes(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, mono: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.lineBreakMode = .byWordWrapping
        return [.font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: p]
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false, width: CGFloat? = nil) {
        let a = attributes(size, weight, color, mono: mono)
        if let width {
            var t = s
            while t.count > 3, (t as NSString).size(withAttributes: a).width > width { t = String(t.dropLast(2)) + "…" }
            (t as NSString).draw(at: p, withAttributes: a)
        } else {
            (s as NSString).draw(at: p, withAttributes: a)
        }
    }

    /// A message: wrapped text in a rounded bubble whose top edge is `top`. Answers its height.
    private func bubble(_ s: String, top: CGFloat, x: CGFloat, width: CGFloat, fill: NSColor, size: CGFloat) -> CGFloat {
        let a = attributes(size, .regular, Self.ink)
        let inner = width - 40
        let bounds = (s as NSString).boundingRect(with: NSSize(width: inner, height: 1000), options: [.usesLineFragmentOrigin], attributes: a)
        let h = ceil(bounds.height) + 32
        let r = NSRect(x: x, y: top - h, width: width, height: h)
        if fill != .clear { fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill() }
        (s as NSString).draw(with: NSRect(x: r.minX + 20, y: r.minY + 16, width: inner, height: h - 32), options: [.usesLineFragmentOrigin], attributes: a)
        return h
    }
}

extension AgentsDemo {
    /// `--agent-demo` (the homepage loop), or `--agent-demo=<mode>`: hero, setup, login (AgentsDemoClips.swift).
    static var mode: String? {
        guard let a = CommandLine.arguments.first(where: { $0 == "--agent-demo" || $0.hasPrefix("--agent-demo=") }) else { return nil }
        return a == "--agent-demo" ? "loop" : String(a.dropFirst("--agent-demo=".count))
    }
}

extension AgentSpike {
    /// The demo run: the person signs in to the bakery (the fixture site's session), then Claude orders (the loop and
    /// the hero), or one of the clips.
    func demoScenario(_ done: @escaping () -> Void) {
        let demo = AgentsDemo(spike: self)
        switch AgentsDemo.mode {
        case "setup": return demo.setupClip(done)
        case "login": return demo.loginClip(done)
        case "loop", "hero", nil: break
        default:
            note("FAIL agentspike demo: unknown --agent-demo mode \(AgentsDemo.mode ?? "")")
            return done()
        }
        demoPages = demo.page
        personSignsIn { ok in
            self.check(ok, "demo: the person is signed in to the fixture site")
            self.personState = (self.app.controllers.count, self.runner.c.shownTabID, self.personPage()?.url?.absoluteString)
            if AgentsDemo.mode == "hero" { demo.hero(done) } else { demo.run(done) }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircCore

@main
struct FeaturesAdapter {
    static var engine: BrowserEngine!
    static var windows: [EngineWindow] = []
    static var tabs: [EngineTab] = []
    static var done = false
    static func main() {
        exit(ChromiumRuntime.run {
            engine = ChromiumEngine()
            for _ in 0..<2 {
                let w = engine.makeWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600))
                w.window.contentView = w.hostView
                w.window.orderFront(nil)
                windows.append(w)
            }
            engine.loadProfile(directory: "Adapter One") { one in
                engine.loadProfile(directory: "Adapter Two") { two in
                    guard let one, let two else { finish("profiles"); return }
                    tabs = [one, two].map { windows[0].openTab(url: URL(string: "data:text/html,<input><p>Fixture</p>"), profile: $0, foreground: false) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { finish("deadline") }
        })
    }
    static func run() {
        let w = windows[0], little = windows[1]
        let panes = [NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600)),
                     NSView(frame: NSRect(x: 400, y: 0, width: 400, height: 600))]
        panes.forEach { w.hostView.addSubview($0) }
        do { try w.presentPanes([(tabs[0], panes[0]), (tabs[1], panes[1])], focused: tabs[1]) }
        catch { finish("panes \(error)"); return }
        tabs[0].evaluate("window.marker = 'live'; document.querySelector('input').value='form'; marker") { _ in
            do {
                let tab = tabs[0]
                try little.moveTab(tab, profile: tab.profile, to: little.hostView)
                guard little.tabs(for: tab.profile).first === tab else { finish("wrapper lost"); return }
                do {
                    try w.moveTab(tab, profile: tabs[1].profile, to: panes[0])
                    finish("profile mismatch accepted"); return
                } catch {}
                try w.moveTab(tab, profile: tab.profile, to: panes[0])
                // Let both asynchronous didRemove callbacks run, testing out-and-back identity.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard w.tabs(for: tab.profile).first === tab else { finish("return wrapper lost"); return }
                    w.focusPane(tab)
                    tab.evaluate("marker + ':' + document.querySelector('input').value") { value in
                        guard value as? String == "live:form" else { finish("state lost"); return }
                        do {
                            let overlay = NSView(frame: NSRect(x: 60, y: 60, width: 500, height: 400))
                            w.hostView.addSubview(overlay)
                            let peek = try w.openPeek(url: URL(string: "about:blank")!, opener: tab, in: overlay)
                            guard peek.profile === tab.profile else { finish("peek profile"); return }
                            try w.moveTab(peek, profile: tab.profile, to: panes[0])
                            peek.close()
                            w.activateTab(tab)
                            finish(nil)
                        } catch { finish("peek \(error)") }
                    }
                }
            } catch { finish("move \(error)") }
        }
    }
    static func finish(_ error: String?) {
        guard !done else { return }; done = true
        let prefix = "--adapter-report="
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) {
            try? (error.map { "FAIL \($0)\n" } ?? "PASS Swift panes, profile refusal, move-out-and-back wrapper identity, live state, Peek promotion\n")
                .write(toFile: String(arg.dropFirst(prefix.count)), atomically: true, encoding: .utf8)
        }
        AircEngine.shared?.quit()
    }
}

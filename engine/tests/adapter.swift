// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircCore

// Link alongside BrowserEngine.swift and ChromiumEngine.swift, then replace the
// executable in a scratch copy of the signed host bundle and re-sign it.
@main
struct AdapterSmoke {
    static var finished = false
    static var engine: BrowserEngine?
    static var window: EngineWindow?
    static var tabs: [EngineTab] = []
    static func main() {
        exit(ChromiumRuntime.run {
            NSApp.setActivationPolicy(.regular)
            let e = ChromiumEngine()
            engine = e
            let w = e.makeWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650))
            window = w
            w.window.contentView = w.hostView
            w.window.orderFront(nil)
            e.loadProfile(directory: "Adapter One") { one in
                e.loadProfile(directory: "Adapter Two") { two in
                    guard let one, let two else { finish(false); return }
                    for profile in [one, two] {
                        w.prepareProfile(profile)
                        let tab = w.openTab(url: URL(string: "data:text/html,<title>Adapter</title><h1>Swift-owned window</h1>"),
                                            profile: profile, foreground: true)
                        tabs.append(tab)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check(0) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(false) }
        })
    }
    static func check(_ index: Int) {
        guard index < tabs.count else {
            commands()
            return
        }
        let tab = tabs[index]
        NSLog("adapter check %d title=%@ loading=%d", index, tab.title, tab.isLoading)
        window?.activateTab(tab)
        guard window?.activeProfile?.directory == tab.profile.directory else { finish(false); return }
        tab.evaluate("({title:document.title, value:42})") { value in
            NSLog("adapter evaluate %@", String(describing: value))
            guard let value = value as? [String: Any], value["title"] as? String == "Adapter",
                  value["value"] as? Int == 42 else { finish(false); return }
            tab.snapshot { image in
                NSLog("adapter snapshot %@", String(describing: image))
                guard image != nil else { finish(false); return }
                check(index + 1)
            }
        }
    }
    static func commands() {
        guard let tab = tabs.first else { finish(false); return }
        window?.activateTab(tab)
        tab.zoom(step: 1)
        guard tab.zoomFactor > 1 else { finish(false); return }
        tab.zoom(step: -1)
        tab.zoom(step: 0)
        guard abs(tab.zoomFactor - 1) < 0.001 else { finish(false); return }
        tab.find("Swift", forward: true) { found, matches in
            guard found, matches == 1 else { finish(false); return }
            tab.find("no-such-text", forward: false) { found, matches in
                guard !found, matches == 0 else { finish(false); return }
                tab.stopFinding()
                tab.evaluate("window.reloadMarker = 42") { _ in
                    tab.reloadIgnoringCache()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        tab.evaluate("typeof window.reloadMarker") { value in
                            guard value as? String == "undefined" else { finish(false); return }
                            devTools(tab, console: false)
                        }
                    }
                }
            }
        }
    }
    static func devTools(_ tab: EngineTab, console: Bool) {
        guard tab.showDevTools(console: console) else { finish(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard NSApp.windows.contains(where: { $0.title == "Developer Tools" && $0.isVisible &&
                !($0.contentView?.subviews.isEmpty ?? true) }),
                let engine = engine as? ChromiumEngine else { finish(false); return }
            engine.snapshotDevTools(for: tab) { image in
                guard let image, save(image, name: console ? "console.png" : "devtools.png") else { finish(false); return }
                engine.closeDevTools(for: tab)
                if console {
                    window?.deactivateAll()
                    finish(window?.activeProfile == nil)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { devTools(tab, console: true) }
                }
            }
        }
    }
    static func save(_ image: NSImage, name: String) -> Bool {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--adapter-report=") }),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
        let path = URL(fileURLWithPath: String(arg.dropFirst("--adapter-report=".count)))
            .deletingLastPathComponent().appendingPathComponent(name)
        do { try png.write(to: path); return true } catch { return false }
    }
    static func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        NSLog("adapter finished %d", ok)
        let prefix = "--adapter-report="
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) {
            try? (ok ? "PASS Swift adapter: two profiles, switching, evaluate, snapshot, deactivateAll, zoom, find results, cache-bypass reload, DevTools and console panels\n" : "FAIL Swift adapter\n")
                .write(toFile: String(arg.dropFirst(prefix.count)), atomically: true, encoding: .utf8)
        }
        AircEngine.shared?.quit()
    }
}

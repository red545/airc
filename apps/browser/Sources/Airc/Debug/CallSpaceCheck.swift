// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    /// Scratch-only fake devices. No DevTools attachment: it would itself prevent discarding.
    func callSpaceScenario() {
        #if canImport(AircCore)
        guard app?.engine is ChromiumEngine,
              CommandLine.arguments.contains("--use-fake-device-for-media-stream"),
              CommandLine.arguments.contains("--use-fake-ui-for-media-stream"),
              let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--airc-test-url=") }),
              let url = URL(string: String(arg.dropFirst("--airc-test-url=".count))),
              url.host == "127.0.0.1" else {
            check(false, "callspace requires loopback and fake media flags"); return
        }
        var home = "", same = "", other = "", call = "", loadID: String?
        var keeper: NSWindow?
        func sample(_ label: String) {
            step { [self] done in
                guard let page = c.engineTab(for: call) else {
                    check(false, "callspace missing tab"); done(); return
                }
                if (app?.engine as? ChromiumEngine)?.isDiscarded(page) == true { check(false, "callspace \(label): discarded"); done(); return }
                page.evaluate("state()") { [self] value in
                    let state = value as? [String: Any] ?? [:]
                    let id = state["id"] as? String
                    if loadID == nil { loadID = id }
                    let tracks = state["tracks"] as? [[String: Any]] ?? []
                    let peers = state["peers"] as? [String] ?? []
                    check(id != nil && id == loadID && tracks.count == 2 && tracks.allSatisfy { $0["state"] as? String == "live" }
                          && peers == ["connected", "connected"], "callspace \(label): \(state)")
                    done()
                }
            }
        }
        run { [self] in
            do {
                home = c.currentSpaceID
                let first = c.store.selectedSpace
                let p = try c.profiles.createProfile(name: "Call test", emoji: "", color: nil)
                same = try c.store.createSpace(name: "Same profile", icon: nil, theme: first.theme, profileID: first.profileID, after: home).id
                other = try c.store.createSpace(name: "Other profile", icon: nil, theme: first.theme, profileID: p.id, after: same).id
                for s in [same, other] { _ = try c.store.openTab(url: "data:text/html,<title>Other</title>", inSpace: s) }
                call = try c.store.openTab(url: url.absoluteString, inSpace: home).id
                c.reloadAll(animated: false); c.switchToSpace(home, animated: false); c.show(call, focus: false)
            } catch { check(false, "callspace setup: \(error)") }
        }
        wait(5); sample("initial")
        for mode in ["same", "other", "timeout", "hidden"] {
            run { [self] in
                if mode == "timeout" { WindowController.unloadOverride = 1; c.applyUnloadSetting() }
                if mode == "hidden" {
                    // AppKit terminates this app after its last window is ordered
                    // out. Keep a scratch background window while hiding it.
                    keeper = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 100, height: 60),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                    keeper?.title = "Call test"; keeper?.orderFront(nil)
                    c.window.orderOut(nil)
                }
                else { c.switchToSpace(mode == "same" ? same : other, animated: false) }
            }
            wait(2)
            if mode != "timeout" {
                run { [self] in check(AircEngine.simulateMemoryPressure(forTesting: 2), "callspace \(mode): pressure accepted") }
            }
            wait(3); sample(mode)
            run { [self] in
                WindowController.unloadOverride = nil; c.applyUnloadSetting()
                c.window.orderFront(nil); keeper?.orderOut(nil); keeper = nil; c.switchToSpace(home, animated: false); c.show(call, focus: false)
            }
            wait(2); sample("return-" + mode)
        }
        run { [self] in c.engineTab(for: call)?.evaluate("stop()", completion: nil) }
        #else
        note("callspace: Chromium only")
        #endif
    }
}
#endif

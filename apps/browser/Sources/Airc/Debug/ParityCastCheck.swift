// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// No screen/camera capture. Fake-provider routes never mirror pixels or send media.
extension SnapshotRunner {
    func parityCastScenario() {
        let center = CastCenter.shared
        let fake = CommandLine.arguments.contains("--airc-test=mediaRouteProvider")
        var server: LocalPageServer?
        var address = ""
        step { done in
            server = LocalPageServer(pages: ["/": "<title>Cast fixture</title><h1>Cast fixture</h1>"])
            server?.start { port in
                if let port { address = "http://127.0.0.1:\(port)/" }
                done()
            }
        }
        run { [self] in
            if let tab = try? c.store.openTab(url: address, inSpace: c.currentSpaceID) {
                c.reloadAll(animated: false); c.show(tab.id, focus: false)
            }
        }
        step { [self] done in
            waitUntil({ self.c.promptShownPage?.title == "Cast fixture" }, timeout: 15) { done() }
        }
        run { [self] in
            check(CommandMenus.all.contains { $0.id == "view.cast" }, "ParityCastCheck: View Cast command")
            check(c.commandActions().contains { $0.title == "Cast…" }, "ParityCastCheck: Command Bar Cast command")
            check(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] == ["_googlecast._tcp"], "ParityCastCheck: Bonjour declaration")
            c.showCast()
        }
        wait(5)
        run { [self] in
            check(CastPicker.shared != nil, "ParityCastCheck: native anchored picker")
            if app?.engine is WebKitEngine {
                check(!center.supported && center.message.contains("AirPlay"), "ParityCastCheck: WebKit explains native AirPlay and unavailable Cast")
            } else {
                check(center.dialogID > 0, "ParityCastCheck: engine host callback arrived")
                if !fake { check(center.sinks.isEmpty, "ParityCastCheck: no-device discovery") }
            }
        }
        capture("cast-picker")
        if fake {
            run { [self] in
                let sink = center.sinks.first { $0.id == "ac-test-sink" }
                check(sink != nil, "ParityCastCheck: gated Chromium fake sink discovered")
                if let sink { center.start(sink) }
            }
            wait(2)
            run { [self] in
                check(center.isCasting(c.promptShownPage), "ParityCastCheck: fake route connected and tab indicator active")
                center.routes([], profile: "unrelated-fixture-profile")
                check(center.isCasting(c.promptShownPage), "ParityCastCheck: another profile cannot clear this route")
            }
            run { CastPicker.hide() }
            wait(0.3)
            run { [self] in
                check(!center.sessions.isEmpty, "ParityCastCheck: route survives picker close")
                center.sessions.forEach { center.stop($0) }
            }
            wait(2)
            run { [self] in check(center.sessions.isEmpty, "ParityCastCheck: route termination removes session") }
        } else {
            // Inject only the UI callback; this is NOT a macOS permission grant/revocation.
            run { [self] in
                guard let page = c.promptShownPage, center.supported else { return }
                let id = center.dialogID
                center.receive(["id": id, "open": true, "permissionRejected": true, "sinks": []], page: page)
                check(center.permissionDenied && center.message.contains("System Settings"), "ParityCastCheck: simulated denied permission has recovery instructions")
                center.receive(["id": id, "open": true, "permissionRejected": false, "sinks": []], page: page)
                check(!center.permissionDenied && center.sinks.isEmpty, "ParityCastCheck: simulated grant returns to safe no-device state")
                center.retry()
            }
            wait(2)
            run { [self] in
                if center.supported { check(center.dialogID > 0, "ParityCastCheck: discovery reconnects after Try Again") }
            }
        }
        run { CastPicker.hide() }
        run { [self] in check(CastPicker.shared == nil && center.dialogID == 0, "ParityCastCheck: close releases dialog") }
        #if canImport(AircCore)
        if !(app?.engine is WebKitEngine) {
            run { [self] in
                guard let page = c.promptShownPage as? ChromiumTab else { return }
                // Host-granted transient activation, confined to this scripted loopback fixture.
                page.core.perform(NSSelectorFromString("grantUserActivationToFrame:"), with: "")
                page.evaluate("window.castResult='pending'; new PresentationRequest('cast:0F5096E8').start().then(()=>window.castResult='connected',e=>window.castResult=e.name); 'requested'", completion: nil)
            }
            wait(3)
            run { [self] in check(center.dialogID > 0 && CastPicker.shared != nil, "ParityCastCheck: site Presentation API opens native picker") }
            run { CastPicker.hide() }
            wait(1)
            step { [self] done in
                c.promptShownPage?.evaluate("window.castResult") { value in
                    let result = value as? String ?? "missing"
                    self.check(result != "pending" && result != "connected" && result != "missing", "ParityCastCheck: cancelling site request rejects its promise (\(result))")
                    done()
                }
            }
        }
        #endif
        run { server = nil }
    }
    func mkCastShots(_ d: MarketingDemo) {
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in c.showCast() }
        wait(5)
        mkWindowShot("cast-picker")
        run { CastPicker.hide() }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING && canImport(AircCore)
import AppKit
import AircKit

extension SnapshotRunner {
    func redirectsScenario() {
        step { [self] done in
            Task { @MainActor in
                await RedirectCheck(runner: self).run()
                done()
            }
        }
    }
}

/// Exercise the real Chromium loader proxy, including the unchanged-target and rewritten-target branches.
@MainActor private final class RedirectCheck {
    let runner: SnapshotRunner
    var server: LocalPageServer?
    var port: UInt16 = 0
    var evidence: [[String: Any]] = []
    init(runner: SnapshotRunner) { self.runner = runner }
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var origin: String { "http://localhost:\(port)" }
    func check(_ good: Bool, _ message: String) { runner.check(good, "redirects: " + message) }
    func js(_ tab: EngineTab, _ script: String) async -> Any? {
        await withCheckedContinuation { resume in tab.evaluate(script) { resume.resume(returning: $0) } }
    }
    func wait(_ tab: EngineTab, url: String, seconds: Double = 12) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if !tab.isLoading, await js(tab, "location.href") as? String == url,
               await js(tab, "document.readyState") as? String == "complete" { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    func requests() async -> [[String: String]] {
        guard let response = try? await URLSession.shared.data(from: URL(string: origin + "/requests")!),
              let rows = try? JSONSerialization.jsonObject(with: response.0) as? [[String: String]] else { return [] }
        return rows
    }
    func visit(_ tab: EngineTab, name: String, start: String, final: String, paths: [String], redirects: Int?, history: [String]) async {
        tab.load(URL(string: start)!)
        let landed = await wait(tab, url: final)
        let actual = await js(tab, "location.href") as? String ?? ""
        check(landed && actual == final, name + " reaches the exact final URL")
        let count = await js(tab, "performance.getEntriesByType('navigation')[0]?.redirectCount") as? Int ?? -1
        if let redirects { check(count == redirects, name + " browser redirect count \(count) == \(redirects)") }
        let rows = await requests().filter { paths.contains($0["path"] ?? "") }
        check(rows.map { $0["path"] ?? "" } == paths, name + " server receives exactly \(paths.count - 1) redirects and one final request")
        evidence.append(["name": name, "start": start, "final": final, "actual": actual,
                         "navigationRedirectCount": count, "requests": rows, "expectedHistory": history])
    }
    func run() async {
        defer { server?.stop() }
        var received: [[String: String]] = [] // read/written only on LocalPageServer's serial queue
        server = LocalPageServer(pages: [:])
        guard let server else { check(false, "loopback server created"); return }
        port = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0 ?? 0) } }
        guard port != 0 else { check(false, "loopback server listening"); return }
        let base = origin, fixturePort = port
        server.requestHandler = { request in
            if request.path == "/requests" {
                return .init(headers: ["Content-Type": "application/json"], body: "", data: try? JSONSerialization.data(withJSONObject: received))
            }
            received.append(["method": request.method, "target": request.target, "path": request.path])
            let prefix = request.path.hasPrefix("/on/") ? "/on" : "/off"
            let suffix = String(request.path.dropFirst(prefix.count))
            func hop(_ status: String, _ target: String) -> LocalPageServer.Page {
                .init(status: status, headers: ["Location": target, "Timing-Allow-Origin": "*"], body: "")
            }
            switch suffix {
            case "/chain/start": return hop("302 Found", base + prefix + "/chain/one")
            case "/chain/one": return hop("301 Moved Permanently", base + prefix + "/chain/two")
            case "/chain/two": return hop("307 Temporary Redirect", base + prefix + "/chain/final")
            case "/cross/start": return hop("302 Found", "http://127.0.0.1:\(fixturePort)" + prefix + "/cross/final")
            case "/post/form": return .init(body: "<form method='POST' action='\(prefix)/post/send'><input name='value' value='synthetic'></form>")
            case "/post/send": return hop("303 See Other", base + prefix + "/post/final")
            case "/rewrite/start": return hop("302 Found", base + prefix + "/rewrite/final?tracking=drop&keep=yes")
            default: return .init(headers: ["Timing-Allow-Origin": "*"], body: "<!doctype html><title>Redirect fixture</title><p>\(request.method) \(request.target)</p>")
            }
        }
        let profile = c.store.profile(ofSpace: c.currentSpaceID).id
        guard let row = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID) else { check(false, "tab created"); return }
        c.reloadAll(animated: false); c.show(row.id, focus: false)
        guard let tab = c.engineTab(for: row.id) else { check(false, "engine tab created"); return }
        check(!(tab is WebKitTab), "fixture is using Chromium, not a WebKit fallback")
        for enabled in [true, false] {
            let mode = enabled ? "on" : "off", prefix = "/" + (enabled ? "on" : "off")
            await withCheckedContinuation { resume in
                app.blocking.installCheckRules("||localhost^$removeparam=tracking\n", profile: profile, enabled: enabled) { resume.resume() }
            }
            check(app.blocking.settings.configuration(profile).enabled == enabled && app.blocking.failures.isEmpty,
                  "blocking \(mode) policy installed")
            let chain = ["start", "one", "two", "final"].map { prefix + "/chain/" + $0 }
            await visit(tab, name: mode + " 302→301→307", start: origin + chain[0], final: origin + chain[3], paths: chain, redirects: 3, history: chain.map { origin + $0 })
            let cross = [prefix + "/cross/start", prefix + "/cross/final"]
            let crossFinal = "http://127.0.0.1:\(port)" + cross[1]
            // Navigation Timing hides cross-origin counts. The post-quit History verifier checks its exact chain.
            await visit(tab, name: mode + " cross-site302", start: origin + cross[0], final: crossFinal, paths: cross, redirects: nil, history: [origin + cross[0], crossFinal])
            let form = origin + prefix + "/post/form", postFinal = origin + prefix + "/post/final"
            tab.load(URL(string: form)!)
            let formReady = await wait(tab, url: form); check(formReady, mode + " POST form loaded")
            _ = await js(tab, "document.forms[0].submit(); true")
            let posted = await wait(tab, url: postFinal)
            let postPaths = [prefix + "/post/send", prefix + "/post/final"]
            let postRows = await requests().filter { postPaths.contains($0["path"] ?? "") }
            let postCount = await js(tab, "performance.getEntriesByType('navigation')[0]?.redirectCount") as? Int ?? -1
            check(posted && postRows.map { $0["method"] ?? "" } == ["POST", "GET"] && postRows.map { $0["path"] ?? "" } == postPaths,
                  mode + " 303 changes POST to GET and lands exactly once")
            check(postCount == 1, mode + " POST303 browser redirect count \(postCount) == 1")
            evidence.append(["name": mode + " POST303", "final": postFinal, "expectedHistory": postPaths.map { origin + $0 }, "requests": postRows, "navigationRedirectCount": postCount])
            let rewrite = [prefix + "/rewrite/start", prefix + "/rewrite/final"]
            let query = enabled ? "?keep=yes" : "?tracking=drop&keep=yes"
            let rewriteFinal = origin + rewrite[1] + query
            await visit(tab, name: mode + " rewritten target", start: origin + rewrite[0], final: rewriteFinal, paths: rewrite,
                        redirects: enabled ? 2 : 1, history: [])
            let rewriteRows = await requests().filter { $0["path"] == rewrite[1] }
            check(rewriteRows.map { $0["target"] ?? "" } == [rewrite[1] + query], mode + " redirect target preserves keep and applies removeparam only when enabled")
            tab.load(URL(string: "https://google.com/")!)
            let google = await wait(tab, url: "https://www.google.com/", seconds: 25)
            let actual = await js(tab, "location.href") as? String ?? ""
            check(google, mode + " real https://google.com/ reaches https://www.google.com/ (\(actual))")
            evidence.append(["name": mode + " public Google", "start": "https://google.com/", "final": "https://www.google.com/", "actual": actual, "expectedHistory": []])
        }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: runner.dir.appendingPathComponent("redirect-evidence.json"))
        } catch { check(false, "redirect evidence persisted: \(error)") }
    }
}
#endif

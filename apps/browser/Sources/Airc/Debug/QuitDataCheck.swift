// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import WebKit

/// quitflush: does data written just before a quit survive the relaunch, also when Chromium's teardown watchdog ends a
/// slow quit at 10 s (disk load)? `quitdata-write` sets a cookie, visits a page (a history entry) and adds a Space, then
/// quits at once. `quitdata-read`, on the same data folder, checks all three. AIRC_QUITDATA_TOKEN names this pair's data
/// (cookie, page and Space carry it). Loopback pages only; cookies ignore the port, so the read's new server sees them.
///
/// wkcookie: on WebKit pages the write also reads the cookie back from the page's store before quitting (is it there,
/// is the store persistent?; AIRC_QUITDATA_READBACK=0 skips it, since the read-back is itself a round trip to WebKit's
/// networking process). The cookie page also sets a second cookie from a script (`qfjs_`, sent from the web content
/// process rather than with the response). AIRC_QUITDATA_WAIT=<s> waits that long before the quit. On the WebKit dev engine this
/// pair gets a persistent store (AppDelegate.makeWebKitEngine; other scripted runs keep cookies in memory only, which is
/// why quitflush saw the cookie "lost" there). On Chromium,
/// AIRC_WEBKIT_HOSTS=127.0.0.1 sends the pages to the DRM services' WebKit (HybridEngine.swift) instead.
extension SnapshotRunner {
    private var quitDataToken: String { ProcessInfo.processInfo.environment["AIRC_QUITDATA_TOKEN"] ?? "qf" }
    private var quitDataWait: Double { ProcessInfo.processInfo.environment["AIRC_QUITDATA_WAIT"].flatMap(Double.init) ?? 0 }

    /// The WebKit store of tab `id`, if it is a WebKit page.
    private func quitDataWebKitStore(_ id: String?) -> WKWebsiteDataStore? {
        (id.flatMap { c.engineTab(for: $0) } as? WebKitTab)?.webView.configuration.websiteDataStore
    }

    private func quitDataServer(_ ready: @escaping (LocalPageServer?, String) -> Void) {
        let token = quitDataToken
        guard let server = LocalPageServer(pages: [:]) else { return ready(nil, "") }
        server.requestHandler = { request in
            switch request.path {
            case "/set":
                return .init(headers: ["Set-Cookie": "qf_\(token)=1; Max-Age=86400; Path=/"],
                             body: "<script>document.cookie = 'qfjs_\(token)=1; max-age=86400; path=/'</script>"
                                + "<title>qf set \(token)</title><p>cookie set</p>")
            case "/visit-\(token)":
                return .init(body: "<title>qf visit \(token)</title><p>history entry</p>")
            case "/echo":
                let cookie = request.headers.first { $0.key.lowercased() == "cookie" }?.value ?? ""
                return .init(body: "<title>qf echo [\(cookie)]</title>")
            default: return nil
            }
        }
        server.start { port in ready(port == nil ? nil : server, port.map { "http://127.0.0.1:\($0)" } ?? "") }
    }

    /// Opens `url` in a new tab of the current Space and waits (at most `timeout`) for a title starting with `prefix`.
    /// `opened` gets the tab's ID.
    private func quitDataOpen(_ url: String, _ prefix: String, timeout: Double = 15, opened: ((String) -> Void)? = nil,
                              _ done: @escaping (String?) -> Void) {
        guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID, title: "") else { return done(nil) }
        opened?(t.id)
        c.reloadAll(animated: false)
        c.show(t.id, focus: false)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            let title = c.engineTab(for: t.id)?.title ?? ""
            if title.hasPrefix(prefix) { return done(title) }
            if Date() > deadline { return done(title.isEmpty ? nil : title) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    func quitDataWrite() {
        let token = quitDataToken
        var server: LocalPageServer?
        var base = ""
        var cookieTab: String?
        step { [self] done in quitDataServer { s, b in server = s; base = b; self.check(s != nil, "quitdata-write: loopback server"); done() } }
        waitForPage()
        step { [self] done in
            quitDataOpen(base + "/set", "qf set", opened: { cookieTab = $0 }) { title in
                self.check(title == "qf set \(token)", "quitdata-write: cookie page loaded (\(title ?? "-"))"); done()
            }
        }
        step { [self] done in
            guard ProcessInfo.processInfo.environment["AIRC_QUITDATA_READBACK"] != "0" else { note("quitdata-write: no read-back"); return done() }
            guard let store = quitDataWebKitStore(cookieTab) else { note("quitdata-write: the cookie page is not a WebKit page"); return done() }
            store.httpCookieStore.getAllCookies { cookies in
                let ours = cookies.filter { $0.name == "qf_\(token)" }
                self.check(!ours.isEmpty, "quitdata-write: the WebKit store has the cookie before the quit (\(ours.count) of \(cookies.count), "
                           + "persistent store \(store.isPersistent))")
                done()
            }
        }
        step { [self] done in
            quitDataOpen(base + "/visit-\(token)", "qf visit") { title in
                self.check(title == "qf visit \(token)", "quitdata-write: history page loaded (\(title ?? "-"))"); done()
            }
        }
        run { [self] in
            do {
                _ = try c.store.createSpace(name: "QF \(token)", after: c.store.selectedSpace.id)
                c.reloadAll(animated: false)
                check(true, "quitdata-write: Space added (not flushed by the check)")
            } catch { check(false, "quitdata-write: Space added (\(error))") }
            note(quitDataWait > 0 ? "quitdata-write: waiting \(quitDataWait) s before the quit, token \(token)"
                                  : "quitdata-write: quitting right after the writes, token \(token)")
            _ = server
        }
        if quitDataWait > 0 { wait(quitDataWait) }
    }

    func quitDataRead() {
        let token = quitDataToken
        var base = ""
        var server: LocalPageServer?
        var echoTab: String?
        waitForPage()
        run { [self] in
            let names = c.store.state.spaces.values.map(\.name)
            check(names.contains("QF \(token)"), "quitdata-read: the Space added before the quit is back (\(names.count) Spaces)")
            if let app {
                let hits = c.store.state.profiles.keys.flatMap { app.history.entries(ofProfile: $0) }.filter { $0.url.contains("/visit-\(token)") }
                check(!hits.isEmpty, "quitdata-read: Airc's history has the page visited before the quit (\(hits.count))")
            }
        }
        #if canImport(AircCore)
        step { [self] done in
            guard ProcessInfo.processInfo.environment["AIRC_WEBKIT_HOSTS"]?.contains("127.0.0.1") != true else {
                note("quitdata-read: pages in the DRM services' WebKit, no Chromium history"); return done()
            }
            guard let app, let engine = app.engine as? ChromiumEngine,
                  let profile = c.profiles.engineProfile(for: c.store.profile(ofSpace: c.currentSpaceID).id) else { return done() }
            engine.queryHistory("visit-\(token)", for: profile) { rows in
                self.check(!rows.isEmpty, "quitdata-read: Chromium's history has the page visited before the quit (\(rows.count))")
                done()
            }
        }
        #endif
        step { [self] done in quitDataServer { s, b in server = s; base = b; done() } }
        step { [self] done in
            quitDataOpen(base + "/echo", "qf echo", opened: { echoTab = $0 }) { title in
                let webKit = self.quitDataWebKitStore(echoTab)
                self.check(title?.contains("qf_\(token)=1") == true, "quitdata-read: the cookie set before the quit is sent again (\(title ?? "-"), "
                           + (webKit.map { "WebKit page, persistent store \($0.isPersistent)" } ?? "not a WebKit page") + ")")
                self.check(title?.contains("qfjs_\(token)=1") == true, "quitdata-read: the cookie a script set before the quit is sent again")
                _ = server
                done()
            }
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script favretry` (both engines): a sidebar favicon that failed is asked again on the next trigger, never on a
/// timer (FaviconCache, AircKit's FaviconBackoff), with loopback icons only. The backoff is shortened to 2, 4, 8 s with
/// no tries within a round, so each failure ends a round. Icons are checked in the row's image and layer, so it all
/// holds with the screen locked.
///   - an unloaded pinned row whose icon answers 503 twice, then the icon: blank after the first failure; the row coming
///     on screen before the backoff is over asks nothing; idle past the backoff, nothing asks and no timer waits; the
///     row coming on screen then asks again (the second 503); the network coming back asks again and the icon shows;
///   - the page loading: a pinned row's icon fails while its server is down; back up, nothing asks; the page loads (the
///     engine shows its icon), the cache asks again, and the row shows the cache's icon once the page is closed;
///   - no storms: 13 rows with 12 slow icons (two rows share one): at most 6 fetches at once, as the server saw them,
///     each icon fetched once, a sidebar reload meanwhile asking nothing more;
///   - a private cache: its icon fails, then comes on a page load; nothing written to disk, nothing asked by the shared
///     cache (the `networkRequests` and `diskWrites` hooks);
///   - a page with no icon of its own: its unloaded row asks /favicon.ico on the page's host and port (the loopback
///     server's, never 80), and shows it.
extension SnapshotRunner {
    func faviconRetryScenario() {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFUlEQVR4nGNgYPhPIhrVMKph2GoAAJLb/wFh5Z4RAAAAAElFTkSuQmCC")!
        let icon = LocalPageServer.Page(headers: ["Content-Type": "image/png"], body: "", data: png)
        let busy = LocalPageServer.Page(status: "503 Service Unavailable", body: "try later")
        let served = ServerLog()
        var server: LocalPageServer?
        var base = ""
        var sid = "", profile = ""
        let policy = FaviconBackoff.Policy(ladder: [2, 4, 8, 16], roundRetries: [], pageLoadFloor: 0.5, forgetAfter: 120, limit: 4000)
        let flaky = "/flaky-\(tag).png", pageIcon = "/pl-\(tag).png", privIcon = "/priv-\(tag).png"
        var flakyID = "", pageID = ""
        func row(_ itemID: String) -> TabRowView? {
            guard let p = c.pageView(for: sid) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.kind == .pinned(itemID: itemID) }
        }
        func shows(_ r: TabRowView?) -> Bool {
            guard let f = r?.faviconViewForTesting else { return false }
            return f.shownImage != nil && f.iconLayerHasContents
        }
        func describe(_ r: TabRowView?) -> String {
            guard let f = r?.faviconViewForTesting else { return "no row" }
            return "image \(f.shownImage != nil), layer \(f.iconLayerHasContents), watching \(f.watchedIcon != nil)"
        }
        func backoff(_ path: String) -> FaviconBackoff.Record? { FaviconCache.shared.backoffForTesting(base + path, profile: profile) }
        /// The row comes on screen again (a Space page shown again, the sidebar back): its view is unhidden.
        func reshow(_ r: TabRowView?) {
            r?.isHidden = true
            r?.isHidden = false
        }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                let n = served.add(path)
                if path == flaky { return n <= 2 ? busy : icon }
                if path == pageIcon { return served.down ? busy : icon }
                if path == privIcon { return n == 1 ? busy : icon }
                if path.hasPrefix("/slow-") { var i = icon; i.delay = 1; return i }
                if path == "/favicon.ico" { return icon }
                if path.hasPrefix("/bare-") { return .init(body: "<!doctype html><title>No icon</title><h1>No icon of its own</h1>") }
                if path.hasPrefix("/page-") {
                    return .init(body: "<!doctype html><title>Icon page</title><link rel='icon' href='\(pageIcon)'><h1>Icon page</h1>")
                }
                return nil
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "favretry: a loopback server") }
                done()
            }
        }
        run { [self] in
            guard !base.isEmpty else { return }
            FaviconCache.shared.setPolicyForTesting(policy)
            let home = c.currentSpaceID
            profile = c.store.profile(ofSpace: home).id
            guard let s = try? c.store.createSpace(name: "Icons", profileID: profile, after: home) else {
                return check(false, "favretry: a Space for the checks")
            }
            sid = s.id
            c.switchToSpace(sid, animated: false)
            note("favretry: \(Self.screenLocked ? "the screen is locked" : "screen unlocked"), network watch online \(NetworkWatch.shared.isOnline)")
        }

        // 1. Fails twice, then the icon: each try needs a trigger.
        run { [self] in
            do {
                try pin(base + "/flaky-page.html", title: "Flaky icon", icon: base + flaky, space: sid)
                flakyID = c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? ""
            } catch { check(false, "favretry: the pinned row (\(error))") }
            c.reloadAll(animated: false)
        }
        step { [self] done in waitUntil({ served.count(flaky) >= 1 && backoff(flaky) != nil }, timeout: 6) { done() } }
        run { [self] in
            let r = row(flakyID), rec = backoff(flaky)
            check(served.count(flaky) == 1 && !shows(r) && r?.faviconViewForTesting.watchedIcon == base + flaky
                  && rec?.rounds == 1 && rec?.failure == .transient,
                  "favretry: the first fetch fails (503): the unloaded row is blank and waits for a trigger (\(describe(r)); "
                  + "requests \(served.count(flaky)), backoff \(rec.map { "round \($0.rounds), \($0.failure.rawValue)" } ?? "none"))")
            reshow(r)
        }
        wait(0.4)
        run { [self] in
            check(served.count(flaky) == 1, "favretry: the row coming on screen before the backoff is over asks nothing (requests \(served.count(flaky)))")
        }
        wait(2.4)   // past the first wait (2 s)
        run { [self] in
            let timers = FaviconCache.shared.timersPending
            check(served.count(flaky) == 1 && timers == 0 && !shows(row(flakyID)),
                  "favretry: idle past the backoff, nothing asks (requests \(served.count(flaky))) and no timer waits (\(timers))")
            reshow(row(flakyID))
        }
        step { [self] done in waitUntil({ served.count(flaky) >= 2 && backoff(flaky)?.rounds == 2 }, timeout: 4) { done() } }
        run { [self] in
            let r = row(flakyID), rec = backoff(flaky)
            check(served.count(flaky) == 2 && !shows(r) && rec?.rounds == 2,
                  "favretry: the row coming on screen after it asks again: the second 503, still blank (\(describe(r)); "
                  + "requests \(served.count(flaky)), backoff round \(rec?.rounds ?? 0), "
                  + String(format: "next in %.1f s)", rec.map { $0.due.timeIntervalSinceNow } ?? -1))
            // The network comes back: what NWPathMonitor's report does (it can't be made to report it in a check).
            NotificationCenter.default.post(name: NetworkWatch.restored, object: nil)
        }
        step { [self] done in waitUntil({ shows(row(flakyID)) }, timeout: 5) { done() } }
        run { [self] in
            let r = row(flakyID)
            check(shows(r) && served.count(flaky) == 3 && backoff(flaky) == nil && r?.faviconViewForTesting.watchedIcon == nil,
                  "favretry: the network coming back asks again and the icon appears in the row (\(describe(r)); requests \(served.count(flaky)), "
                  + "backoff \(backoff(flaky) == nil ? "cleared" : "left"))")
        }
        capture("favretry-row")

        // 2. The page loading: the engine shows the page's icon, and the cache asks for its own copy.
        run { [self] in
            served.down = true
            do {
                try pin(base + "/page-\(tag).html", title: "Icon page", icon: base + pageIcon, space: sid)
                pageID = c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? ""
            } catch { check(false, "favretry: the page's pinned row (\(error))") }
            c.reloadAll(animated: false)
        }
        step { [self] done in waitUntil({ backoff(pageIcon) != nil }, timeout: 6) { done() } }
        run { [self] in
            check(served.count(pageIcon) == 1 && !shows(row(pageID)) && backoff(pageIcon) != nil,
                  "favretry: the page's icon fails while its server is down: blank (\(describe(row(pageID))); requests \(served.count(pageIcon)))")
            served.down = false
        }
        wait(2.4)
        var tabID = ""
        run { [self] in
            check(served.count(pageIcon) == 1, "favretry: the server back up, nothing asks while nothing happens (requests \(served.count(pageIcon)))")
            guard let t = try? c.store.openItem(pageID, inSpace: sid, activate: true) else { return check(false, "favretry: the page opens") }
            tabID = t.id
            c.show(t.id, focus: false)
        }
        step { [self] done in waitUntil({ FaviconCache.shared.cached(base + pageIcon) != nil }, timeout: 12) { done() } }
        run { [self] in
            let page = c.engineTab(for: tabID)
            check(FaviconCache.shared.cached(base + pageIcon) != nil,
                  "favretry: the page loading asks again: the cache has its icon (page icon \(page?.favicon != nil), "
                  + "\(page?.faviconURL?.path ?? "-"), requests \(served.count(pageIcon)))")
            c.forgetPage(tabID, close: true)
            c.reloadAll(animated: false)
        }
        wait(0.3)
        run { [self] in
            let r = row(pageID)
            check(c.isPageUnloaded(tabID) && shows(r),
                  "favretry: the page closed again, its unloaded row shows the cache's icon (unloaded \(c.isPageUnloaded(tabID)), \(describe(r)))")
        }

        // 3. No storms: many rows at once.
        var slowIDs: [String] = []
        run { [self] in
            do {
                for i in 0..<13 {
                    try pin(base + "/storm-\(i).html", title: "Storm \(i)", icon: base + "/slow-\(tag)-\(i % 12).png", space: sid)
                    slowIDs.append(c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? "")
                }
            } catch { check(false, "favretry: the storm rows (\(error))") }
            c.reloadAll(animated: false)
        }
        wait(0.5)
        run { [self] in c.reloadAll(animated: false) }
        step { [self] done in waitUntil({ slowIDs.allSatisfy { shows(row($0)) } }, timeout: 10) { done() } }
        run { [self] in
            let shown = slowIDs.filter { shows(row($0)) }.count
            let counts = (0..<12).map { served.count("/slow-\(tag)-\($0).png") }
            let peak = served.peakOverlap(prefix: "/slow-\(tag)-", lasting: 1)
            check(shown == 13 && counts.allSatisfy { $0 == 1 } && peak <= FaviconCache.concurrentFetches,
                  "favretry: 13 rows, 12 slow icons: all shown (\(shown)), each fetched once (\(counts)), at most "
                  + "\(FaviconCache.concurrentFetches) at once (the server saw \(peak); the cache's peak \(FaviconCache.shared.peakConcurrentFetches))")
        }
        capture("favretry-storm")

        // 4. A private cache: its own memory only, its own requests.
        let priv = FaviconCache(memoryOnly: true)
        var privImage: NSImage?
        step { [self] done in
            priv.setPolicyForTesting(policy)
            priv.load(base + privIcon) { first in
                self.check(first == nil, "favretry: private: the first fetch fails (503)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    priv.load(base + privIcon) { privImage = $0; done() }
                }
            }
        }
        run { [self] in
            guard let url = URL(string: base + privIcon) else { return }
            let own = priv.networkRequests.filter { $0 == url }.count
            check(privImage != nil && own == 2 && priv.diskWrites.isEmpty && priv.fileForTesting(url) == nil
                  && !FaviconCache.shared.networkRequests.contains(url) && !FaviconCache.shared.diskWrites.contains(url),
                  "favretry: private: the icon comes on the next page load (\(privImage != nil), \(own) requests of its own); "
                  + "nothing on disk (\(priv.diskWrites.count) writes), nothing asked by the shared cache")
        }

        // 5. A page with no icon of its own: the guess keeps the page's port.
        var bare = "", bareID = ""
        var guessedBefore = 0
        run { [self] in
            bare = base + "/bare-\(tag).html"
            guessedBefore = served.count("/favicon.ico")
            let guess = FaviconCache.guess(for: bare), port = URL(string: base)?.port
            check(guess == base + "/favicon.ico" && port != nil && port != 80,
                  "favretry: a page with no icon guesses /favicon.ico on its own host and port (\(guess ?? "none"), port \(port ?? 0))")
            do {
                try pin(bare, title: "No icon", icon: nil, space: sid)
                bareID = c.store.children(of: .pinned(spaceID: sid), parent: nil).last?.id ?? ""
            } catch { check(false, "favretry: the no-icon row (\(error))") }
            c.reloadAll(animated: false)
        }
        step { [self] done in waitUntil({ shows(row(bareID)) }, timeout: 6) { done() } }
        run { [self] in
            let r = row(bareID), asked = served.count("/favicon.ico") - guessedBefore
            let portless = FaviconCache.shared.networkRequests.filter { $0.host == "127.0.0.1" && $0.port == nil }
            check(shows(r) && asked == 1 && FaviconCache.shared.cached(base + "/favicon.ico") != nil && portless.isEmpty,
                  "favretry: its unloaded row shows the icon from its own server's /favicon.ico (\(describe(r)); that server saw "
                  + "\(asked) request(s), port-less guesses \(portless.map(\.absoluteString)))")
        }

        run { [self] in
            FaviconCache.shared.setPolicyForTesting(.standard)
            note("favretry: requests \(served.summary), watchers left \(FaviconCache.shared.watcherCount), timers \(FaviconCache.shared.timersPending)")
            server?.stop()
        }
    }

    /// What the check's server saw: requests per path, when, and whether its icons are down. Counted on its queue.
    final class ServerLog {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var arrivals: [(path: String, at: CFTimeInterval)] = []
        private var isDown = false

        var down: Bool {
            get { lock.lock(); defer { lock.unlock() }; return isDown }
            set { lock.lock(); isDown = newValue; lock.unlock() }
        }

        func add(_ path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            counts[path, default: 0] += 1
            arrivals.append((path, CACurrentMediaTime()))
            return counts[path]!
        }

        func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }

        /// The most requests under `prefix` open at once, each lasting `lasting` seconds from its arrival.
        func peakOverlap(prefix: String, lasting: Double) -> Int {
            lock.lock(); defer { lock.unlock() }
            let times = arrivals.filter { $0.path.hasPrefix(prefix) }.map(\.at).sorted()
            var peak = 0
            for (i, t) in times.enumerated() {
                peak = max(peak, times[i...].prefix { $0 < t + lasting - 0.05 }.count)
            }
            return peak
        }

        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
    }
}
#endif

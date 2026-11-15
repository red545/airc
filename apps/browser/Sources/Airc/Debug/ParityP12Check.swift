// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Network

/// `--script parityp12`, then `parityp12-relaunch` in a fresh process on the same data dir (both engines): GitHub Live
/// Folders (S15) against a fake GitHub on a loopback port (AircKit's FakeGitHub behind `P12FakeGitHubServer`). No
/// request leaves the Mac: the API, the sign-in pages and the pull requests' own pages are all on 127.0.0.1, tokens
/// stay in memory (no Keychain), and the check fails if any favicon was asked of another host.
///   - New Live Folder… in the Space menu, the + menu and the Command Bar; the sheet makes a repository's folder;
///   - pagination (pages of two), most recently updated first, a status glyph on the folder's row;
///   - created, retitled, merged and closed pull requests at Refresh (the folder menu's), the person's own tab kept;
///   - an unchanged list is free (If-None-Match → 304);
///   - rate limit: "Rate Limited" on the row, Refresh off until GitHub's reset, no request sent;
///   - offline: the rows stay (the offline cache), "Offline" on the row, then back;
///   - Your Pull Requests needs a sign-in ("Sign In" on the row); the device flow signs in; an expired token signs out;
///     a second profile's folder stays signed out (accounts are per profile);
///   - Keep in Folder, filters from the folder menu (Drafts), Stop Updating;
///   - a folder deleted while its request is out: the request is cancelled, nothing lands, ⌘Z brings it back live;
///   - after a relaunch: definitions, rows and the offline cache are kept, and the folder refreshes again.
extension SnapshotRunner {
    func parityP12Scenario() {
        let relaunch = script == "parityp12-relaunch"
        let store = c.store
        let center = LiveFolderCenter.shared
        let engine = app?.engine.name ?? "?"
        func ok(_ cond: Bool, _ what: String) { check(cond, "parityp12 \(engine): " + what) }
        var server: P12FakeGitHubServer?
        var gh: FakeGitHub!
        let repo = "acme/rocket"
        let stateFile = AppPaths.dataDirectory.appendingPathComponent("p12-state.json")
        var repoFolder = "", yoursFolder = "", workFolder = ""
        var ownTab = ""
        func rows(_ folder: String) -> [Item] { store.children(of: store.item(folder)?.container ?? .pinned(spaceID: c.currentSpaceID), parent: folder) }
        func titles(_ folder: String) -> [String] { rows(folder).map(\.displayTitle) }
        func status(_ folder: String) -> LiveFolderStatus? { center.display(folder)?.status }
        func badge(_ folder: String) -> LiveFolderBadgeView? {
            c.pageView(for: store.item(folder)?.spaceID ?? c.currentSpaceID)?.rows[folder]?.subviews.first { $0 is LiveFolderBadgeView } as? LiveFolderBadgeView
        }
        func folderMenu(_ folder: String) -> NSMenu? {
            store.item(folder).map { c.menu(for: .folder($0, depth: 0)) }
        }
        func item(_ m: NSMenu?, _ title: String) -> NSMenuItem? { m?.items.first { $0.title == title } }
        @discardableResult func fire(_ m: NSMenu?, _ title: String) -> Bool {
            guard let i = item(m, title) as? ClosureMenuItem, i.isEnabled else { return false }
            i.fire()
            return true
        }
        func idle(_ folder: @escaping () -> String, timeout: Double = 8) {
            step { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.waitUntil({ !center.refreshing.contains(folder()) }, timeout: timeout) { done() }
                }
            }
        }
        func refresh(_ folder: @escaping () -> String) {
            run { _ = fire(folderMenu(folder()), "Refresh") }
            idle(folder)
        }

        // A fake GitHub on a loopback port; the center talks only to it.
        step { done in
            gh = FakeGitHub(pageSize: 2)
            let s = P12FakeGitHubServer(gh)
            server = s
            s.start { port in
                guard let port else {
                    ok(false, "the fake GitHub listens on a loopback port")
                    return done()
                }
                let base = "http://127.0.0.1:\(port)"
                gh.webBase = base
                gh.apiOrigin = base
                center.endpoint = GitHubEndpoint(api: URL(string: base)!, web: URL(string: base)!)
                center.http = URLSessionLiveHTTP(timeout: 5)
                center.accounts.inMemory = true
                center.accounts.clientIDOverride = "Iv1.fake-p12"
                done()
            }
        }
        if relaunch { return parityP12Relaunch(gh: { gh }, stateFile: stateFile, ok: ok, titles: titles, idle: idle) }

        run { [self] in
            gh.open(repo, 1, "Add the launch checklist", author: "ada")
            gh.open(repo, 2, "Fix telemetry batching", author: "bob")
            gh.open(repo, 3, "WIP: new engine", author: "ada", draft: true, labels: ["engine"])
            // Where New Live Folder… is.
            ok(item(c.spaceMenu(spaceID: c.currentSpaceID), "New Live Folder…") != nil, "New Live Folder… in the Space menu")
            ok(item(c.plusMenu(), "New Live Folder…") != nil, "New Live Folder… in the + menu")
            ok(c.contextCommandActions().contains { $0.title == "New Live Folder…" }, "New Live Folder… in the Command Bar")
            if let i = c.spaceMenu(spaceID: c.currentSpaceID).items.firstIndex(where: { $0.title == "New Folder…" }) {
                ok(c.spaceMenu(spaceID: c.currentSpaceID).items[i + 1].title == "New Live Folder…", "right after New Folder…, as Arc's Live Folder ›")
            }
            // The sheet makes a repository's folder.
            c.newLiveFolder()
        }
        step { [self] done in waitUntil({ c.window.attachedSheet != nil }, timeout: 3) { done() } }
        capture("p12-sheet")
        run { [self] in
            guard let sheet = LiveFolderSheet.active[ObjectIdentifier(c.window)] else { return ok(false, "the New Live Folder sheet opens") }
            ok(sheet.source == .yours && sheet.sourceNote == "Pull requests from you and your team will show up here automatically",
               "the sheet starts on Your Pull Requests, with Arc's line")
            ok(sheet.canDeviceFlow, "Sign In with GitHub… is offered when the build has a client ID")
            sheet.source = .repository
            ok(sheet.repositoryProblem != nil, "a repository source needs a repository")
            sheet.repository = "https://github.com/acme/rocket"
            ok(sheet.repositoryProblem == nil && sheet.query.repository == repo, "a pasted URL is read as owner/name")
            ok(!sheet.needsSignIn, "a public repository needs no account")
            let before = Set(store.state.items.keys)
            sheet.commit()
            repoFolder = store.state.items.keys.first { !before.contains($0) && store.item($0)?.kind == .folder } ?? ""
            ok(center.isLive(repoFolder) && store.item(repoFolder)?.title == "rocket", "Create Live Folder makes a live folder named after the repository")
        }
        idle({ repoFolder })
        wait(0.3)
        run { [self] in
            ok(titles(repoFolder) == ["WIP: new engine", "Fix telemetry batching", "Add the launch checklist"],
               "its pull requests, most recently updated first, from two pages (\(titles(repoFolder)))")
            ok(gh.requests.filter { $0.contains("/repos/acme/rocket/pulls") }.count == 2, "pagination followed GitHub's Link header (\(gh.requests))")
            ok(rows(repoFolder).allSatisfy { $0.savedURL?.hasPrefix(gh.webBase + "/acme/rocket/pull/") == true }, "rows open the pull requests")
            ok(status(repoFolder) == .ok, "status: up to date")
            let b = badge(repoFolder)
            ok(b != nil && b?.isHidden == false && b?.shownText == "", "the row shows the live glyph, no warning")
            ok(item(folderMenu(repoFolder), "Updated just now") != nil, "the folder menu says when it updated")
            ok(c.contextCommandActions().contains { $0.title == "Refresh rocket Live Folder" }, "Refresh in the Command Bar")
            // The person's own tab in the live folder.
            let mine = Item(kind: .tab, container: store.item(repoFolder)!.container, parentID: repoFolder, order: 50,
                            savedURL: gh.webBase + "/notes", title: "My release notes")
            try? store.perform(nil) { store.put(mine) }
            ownTab = mine.id
            // GitHub changes: one new, one retitled, one merged, one closed.
            gh.open(repo, 4, "Ship the docs", author: "cy")
            gh.retitle(repo, 1, "Add the launch checklist (v2)")
            gh.merge(repo, 2)
            gh.close(repo, 3)
        }
        capture("p12-folder")
        refresh({ repoFolder })
        run { [self] in
            ok(titles(repoFolder).first == "Ship the docs", "a new pull request comes in at the top (\(titles(repoFolder)))")
            ok(titles(repoFolder).contains("Add the launch checklist (v2)"), "a retitled one follows")
            ok(!titles(repoFolder).contains("Fix telemetry batching") && !titles(repoFolder).contains("WIP: new engine"),
               "merged and closed ones leave the folder")
            ok(store.item(ownTab) != nil, "the person's own tab in the folder is never touched")
        }
        // ETag: an unchanged list costs nothing.
        var hits = 0
        run { hits = gh.conditionalHits }
        refresh({ repoFolder })
        run { [self] in ok(gh.conditionalHits > hits && center.lastOutcome[repoFolder] == LiveApplyOutcome(), "unchanged: If-None-Match got 304, nothing moved") }

        // Rate limit.
        var count = 0
        run { [self] in
            gh.setRateLimit(remaining: 0, resetAt: Date().addingTimeInterval(1800))
            gh.open(repo, 5, "Not seen yet")
        }
        refresh({ repoFolder })
        wait(0.2)
        run { [self] in
            if case .rateLimited(let until?) = status(repoFolder) { ok(until > Date(), "rate limited until GitHub's reset") }
            else { ok(false, "rate limited (\(String(describing: status(repoFolder))))") }
            ok(badge(repoFolder)?.shownText == "Rate Limited", "the row says Rate Limited (\(badge(repoFolder)?.shownText ?? "-"))")
            ok(badge(repoFolder)?.toolTip?.hasPrefix("GitHub rate limit exceeded") == true, "with Arc's words as its tooltip")
            ok(item(folderMenu(repoFolder), "GitHub rate limit exceeded") != nil, "and at the top of its menu")
            ok(item(folderMenu(repoFolder), "Refresh")?.isEnabled == false, "Refresh waits for the reset")
            count = gh.requestCount
            center.refreshDue(.focus)
            center.refresh(repoFolder)
            ok(gh.requestCount == count && center.refreshing.isEmpty, "no request before the reset, by timer, focus or hand")
            ok(titles(repoFolder).count == 3, "the rows stay")
        }
        capture("p12-rate-limited")
        // Offline: a connection that closes unanswered. (New filters start the folder afresh, past the rate limit.)
        run { [self] in
            gh.setRateLimit(remaining: nil, resetAt: Date())
            gh.setOffline(true)
            center.setQuery(GitHubPullQuery(repository: repo, includeDrafts: false), ofFolder: repoFolder)
        }
        idle({ repoFolder })
        run { [self] in
            ok(status(repoFolder) == .offline, "offline (\(String(describing: status(repoFolder))))")
            ok(badge(repoFolder)?.shownText == "Offline", "the row says Offline")
            ok(titles(repoFolder).count == 3 && center.book?.definition(repoFolder)?.cache.isEmpty == false, "the last list stays (offline cache)")
            gh.setOffline(false)
            center.setQuery(GitHubPullQuery(repository: repo), ofFolder: repoFolder)
        }
        idle({ repoFolder })
        run { [self] in
            ok(status(repoFolder) == .ok && titles(repoFolder).contains("Not seen yet"), "back online, it catches up (\(titles(repoFolder)))")
            gh.open(repo, 6, "Draft: idea", author: "ada", draft: true)
        }
        refresh({ repoFolder })
        run { [self] in
            ok(titles(repoFolder).contains("Draft: idea"), "a draft shows while Drafts is on")
            // Filters from the folder menu: Drafts off.
            ok(fire(folderMenu(repoFolder), "Drafts"), "Drafts in the folder menu")
        }
        idle({ repoFolder })
        run { [self] in
            ok(!titles(repoFolder).contains("Draft: idea") && center.display(repoFolder)?.query.includeDrafts == false, "Drafts off hides drafts")
            // Keep in Folder on a pull request's row.
            let row = rows(repoFolder).first { $0.title == "Ship the docs" }!
            let m = c.menu(for: .pinned(row, depth: 1, nil))
            ok(fire(m, "Keep in Folder"), "Keep in Folder on a pull request's row")
            gh.merge(repo, 4)
        }
        refresh({ repoFolder })
        run { [self] in ok(titles(repoFolder).contains("Ship the docs"), "a kept row stays after its pull request merges") }

        // Your Pull Requests: sign-in, device flow, expiry, per-profile accounts.
        run { [self] in
            gh.open("acme/other", 7, "Review my parser", author: "bob", reviewers: ["ada"])
            yoursFolder = center.create(query: .yours, title: nil, inSpace: c.currentSpaceID, store: store)?.id ?? ""
            ok(store.item(yoursFolder)?.title == "Pull Requests", "Arc's name: Pull Requests")
        }
        idle({ yoursFolder })
        run { [self] in
            ok(status(yoursFolder) == .signedOut, "Your Pull Requests needs a sign-in")
            ok(badge(yoursFolder)?.shownText == "Sign In", "the row says Sign In")
            ok(item(folderMenu(yoursFolder), "Not signed in to GitHub") != nil && item(folderMenu(yoursFolder), "Sign In to GitHub…") != nil,
               "its menu says so and offers Sign In to GitHub…")
            ok(!gh.requests.contains { $0.contains("/search/") }, "nothing was asked without an account")
            gh.setDeviceFlow(pendingPolls: 0, token: "tok-ada", login: "ada")
            c.editLiveFolder(yoursFolder)
            LiveFolderSheet.active[ObjectIdentifier(c.window)]?.startDeviceFlow()
        }
        step { [self] done in
            waitUntil({ LiveFolderSheet.active[ObjectIdentifier(self.c.window)]?.deviceCode != nil }, timeout: 4) { done() }
        }
        capture("p12-device-code")
        step { [self] done in
            waitUntil({ LiveFolderSheet.active[ObjectIdentifier(self.c.window)]?.account == "ada" }, timeout: 12) { done() }
        }
        run { [self] in
            let sheet = LiveFolderSheet.active[ObjectIdentifier(c.window)]
            ok(sheet?.account == "ada", "the device flow signs in (Signed in as ada)")
            ok(NSPasteboard.general.string(forType: .string) == "WDJB-MJHT", "the code is on the clipboard for github.com/login/device")
            sheet?.close()
        }
        idle({ yoursFolder })
        wait(0.3)
        run { [self] in
            ok(Set(titles(yoursFolder)) == ["Add the launch checklist (v2)", "Draft: idea", "Review my parser"],
               "signed in: your pull requests and review requests (\(titles(yoursFolder)))")
            ok(gh.requests.contains { $0.contains("/search/issues") && $0.contains("200") }, "via GitHub's search")
            // A second profile's Space: its own account (none).
            if let work = try? store.createProfile(name: "Work"), let s = try? store.createSpace(name: "Work", profileID: work.id) {
                workFolder = center.create(query: .yours, title: nil, inSpace: s.id, store: store)?.id ?? ""
            }
        }
        idle({ workFolder })
        run { [self] in
            ok(status(workFolder) == .signedOut && status(yoursFolder) == .ok, "a second profile isn't signed in by the first's account")
            gh.revokeToken("tok-ada")
        }
        refresh({ yoursFolder })
        run { [self] in
            ok(status(yoursFolder) == .signedOut, "an expired token: Not signed in to GitHub")
            ok(!titles(yoursFolder).isEmpty, "the rows stay")
            ok(center.book?.definition(yoursFolder).map { !LiveFolderSchedule.isDue($0, trigger: .timer, now: Date()) } == true,
               "no automatic retries until a sign-in")
        }

        // Delete while the request is out.
        run { [self] in
            gh.addToken("tok-ada2", login: "ada")
            center.accounts.save(token: "tok-ada2", login: "ada", forProfile: store.profile(ofSpace: c.currentSpaceID).id)
            gh.setDelay(1.5)
            gh.open(repo, 8, "Arrives too late")
            center.refresh(repoFolder)
            ok(center.inFlight.contains(repoFolder), "a request is out")
            ok(fire(folderMenu(repoFolder), "Delete Folder"), "Delete Folder while it's out")
            ok(!center.inFlight.contains(repoFolder) && !center.isLive(repoFolder), "deleting cancels the request")
        }
        wait(2.0)
        run { [self] in
            ok(!store.state.items.values.contains { $0.title == "Arrives too late" }, "a late answer adds nothing")
            gh.setDelay(0)
            _ = try? store.undo()
            ok(center.isLive(repoFolder) && store.item(ownTab) != nil, "⌘Z brings the folder back, live, with the person's tab")
        }
        refresh({ repoFolder })
        run { [self] in
            ok(titles(repoFolder).contains("Arrives too late"), "and it updates again (\(titles(repoFolder)))")
            let ff = FaviconCache.shared.networkRequests.filter { $0.host != "127.0.0.1" && $0.host != "localhost" }
            ok(ff.isEmpty, "no favicon was asked of another host (\(ff.prefix(3)))")
            let state = ["repo": repoFolder, "yours": yoursFolder, "work": workFolder, "own": ownTab]
            try? JSONSerialization.data(withJSONObject: state).write(to: stateFile)
        }
        capture("p12-final")
        run { [self] in
            // Stop Updating on the second profile's folder: an ordinary folder now.
            center.stopUpdating(workFolder)
            ok(!center.isLive(workFolder) && store.item(workFolder) != nil, "Stop Updating keeps an ordinary folder")
            try? store.flush()
            server?.stop()
        }
    }

    private func parityP12Relaunch(gh: @escaping () -> FakeGitHub, stateFile: URL, ok: @escaping (Bool, String) -> Void,
                                   titles: @escaping (String) -> [String], idle: @escaping (@escaping () -> String, Double) -> Void) {
        let center = LiveFolderCenter.shared
        var saved: [String: String] = [:]
        run { [self] in
            saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateFile))) as? [String: String] ?? [:]
            let repo = saved["repo"] ?? ""
            _ = center.attach(c.store)
            ok(!repo.isEmpty && center.isLive(repo), "after a relaunch the folder is still live")
            ok(!center.isLive(saved["work"] ?? ""), "the stopped folder stays ordinary")
            ok(c.store.item(saved["own"] ?? "") != nil, "the person's tab is kept")
            ok(center.book?.definition(repo)?.cache.isEmpty == false, "the offline cache is kept")
            ok(center.book?.definition(repo)?.query.includeDrafts == false, "its filters are kept")
            ok(titles(repo).contains("Arrives too late"), "its rows are kept (\(titles(repo)))")
            gh().open("acme/rocket", 9, "After the relaunch")
            center.refresh(repo)
        }
        idle({ saved["repo"] ?? "" }, 8)
        run { [self] in
            let repo = saved["repo"] ?? ""
            ok(titles(repo).first == "After the relaunch",
               "and it refreshes again (\(titles(repo)); \(String(describing: center.display(repo)?.status)); \(gh().requests))")
            ok(!titles(repo).contains("Arrives too late"), "rows of pull requests gone from the new GitHub retire")
            _ = self
        }
    }
}

/// FakeGitHub on 127.0.0.1 (an ephemeral port), one request per connection. Offline makes it close connections
/// without an answer, as a dropped network would.
final class P12FakeGitHubServer {
    private let gh: FakeGitHub
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.test.fake-github")

    init(_ gh: FakeGitHub) {
        self.gh = gh
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        listener = try! NWListener(using: params)
    }

    /// Servers in use: a scenario's step closures go once they've run, and the server must outlive them.
    static var running: [P12FakeGitHubServer] = []

    func start(_ ready: @escaping (UInt16?) -> Void) {
        Self.running.append(self)
        var answered = false
        listener.stateUpdateHandler = { [listener] state in
            let port: UInt16?
            switch state {
            case .ready: port = listener.port?.rawValue
            case .failed, .cancelled: port = nil
            default: return
            }
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                ready(port)
            }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return c.cancel() }
            c.start(queue: self.queue)
            self.receive(c, Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        Self.running.removeAll { $0 === self }
    }

    /// The pull requests' site icon: a pull-request glyph (the fake isn't github.com, so no GitHub mark).
    static let icon: Data = {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let s = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                s.draw(in: NSRect(x: (64 - s.size.width) / 2, y: (64 - s.size.height) / 2, width: s.size.width, height: s.size.height))
            }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }()

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return c.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { c.cancel() } else { self.receive(c, buffer) }
                return
            }
            let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
            var lines = head.components(separatedBy: "\r\n")
            let request = lines.removeFirst().split(separator: " ")
            var headers: [String: String] = [:]
            for l in lines {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[String(l[..<i]).trimmingCharacters(in: .whitespaces)] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
            let body = buffer[end.upperBound...]
            if body.count < length, !done, error == nil { return self.receive(c, buffer) }
            let method = request.first.map(String.init) ?? "GET"
            let target = request.dropFirst().first.map(String.init) ?? "/"
            let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
            self.answer(c, method: method, path: parts.first ?? "/", query: parts.count > 1 ? parts[1] : "", headers: headers, body: Data(body))
        }
    }

    private func answer(_ c: NWConnection, method: String, path: String, query: String, headers: [String: String], body: Data) {
        if gh.isOffline { return c.cancel() }
        let delay = gh.answerDelay
        queue.asyncAfter(deadline: .now() + delay) { [gh] in
            let r: FakeGitHub.Response
            if path == "/favicon.ico" {
                r = FakeGitHub.Response(status: 200, headers: ["Content-Type": "image/png"], body: P12FakeGitHubServer.icon)
            } else if !(path.hasPrefix("/repos/") || path.hasPrefix("/search/") || path == "/user" || path.hasPrefix("/login/")) {
                // A pull request's page or icon: a plain page, so rows that load show something.
                r = FakeGitHub.Response(status: 200, headers: ["Content-Type": "text/html"], body: Data("<title>Pull request</title>".utf8))
            } else {
                r = gh.respond(method: method, path: path, query: query, headers: headers, body: body)
            }
            let reason = [200: "OK", 304: "Not Modified", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 502: "Bad Gateway"][r.status] ?? "Status"
            var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
            var hs = r.headers
            hs["Content-Length"] = String(r.body.count)
            hs["Connection"] = "close"
            for (k, v) in hs { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8)
            if r.status != 304 { out.append(r.body) }
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// mcpfeedback's part of `--script agentspike` (after the approval checks; the client is the check's own helper,
/// allowed, in the Agent profile):
/// - rules per app (Settings › Agents › Rules…): a never-open site refused in open_window, navigate and on a page a
///   link landed on; the Airc Agent's global "never use" list too; a profile rule refuses use_profile and a connection
///   asking for another profile;
/// - files: upload_file refuses paths outside the allowed folders (and a symlink out of them), sets the page's file
///   field from the app's folder and from the chosen upload folder; a download from an agent page lands in the app's
///   folder (list_downloads names it) and not in the person's Downloads list;
/// - "Needs you": a sign-in page, a 401 and a captcha mark the row (and the folder's badge), the tool result says the
///   page waits for the person, the notification step fires, and a normal page clears it.
extension AgentSpike {
    static let uploadPage = """
    <!doctype html><html><head><title>Upload</title><style>body{margin:0;font:16px -apple-system,sans-serif}
    #f{position:absolute;left:40px;top:40px;width:300px;height:40px}#out{position:absolute;left:40px;top:120px}</style></head><body>
    <input type="file" id="f" multiple><p id="out">none</p>
    <script>document.getElementById('f').addEventListener('change',function(e){document.getElementById('out').textContent='picked '+
    [].map.call(e.target.files,function(x){return x.name+':'+x.size}).join(',')})</script></body></html>
    """
    static let downloadPage = """
    <!doctype html><html><head><title>Get it</title><style>body{margin:0;font:16px -apple-system,sans-serif}
    #a{position:absolute;left:40px;top:40px;font-size:30px;line-height:40px}</style></head><body>
    <a id="a" href="/agent-file.txt" download="agent-file.txt">Get the file</a></body></html>
    """

    func feedbackPage(_ r: LocalPageServer.Request) -> LocalPageServer.Page? {
        switch r.path {
        case "/upload": return LocalPageServer.Page(body: Self.uploadPage)
        case "/wiki":
            // The saved article (scripts/fixtures: AIRC_WIKI_FIXTURE in runs), else a long page.
            if let p = ProcessInfo.processInfo.environment["AIRC_WIKI_FIXTURE"], let d = FileManager.default.contents(atPath: p) {
                return LocalPageServer.Page(headers: ["Content-Type": "text/html; charset=utf-8"], body: "", data: d)
            }
            return LocalPageServer.Page(body: "<!doctype html><title>Long</title>" + String(repeating: "<p>Paragraph of a long article.</p>", count: 600))
        case "/dl": return LocalPageServer.Page(body: Self.downloadPage)
        case "/agent-file.txt":
            return LocalPageServer.Page(headers: ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"agent-file.txt\""],
                                        body: "made by the agent check\n")
        case "/captcha":
            return LocalPageServer.Page(body: "<!doctype html><title>Check</title><h1>One moment</h1><div class=\"g-recaptcha\" style=\"width:300px;height:80px\"></div>")
        case "/denied":
            return LocalPageServer.Page(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Bearer"], body: "<!doctype html><title>Denied</title><h1>Sign in required</h1>")
        default: return nil
        }
    }

    func feedbackChecks(_ done: @escaping () -> Void) {
        scrollChecks { self.rulesChecks { self.fileChecks { self.needsYouChecks {
            ProcessInfo.processInfo.environment["AIRC_REAL_KEYS"] == "1" ? self.realInputChecks(done) : done()
        } } } }
    }

    // MARK: Scroll (0.1.28: five failures in a row on en.wikipedia.org)

    /// Five scrolls down, one up, one at the cursor, on a Wikipedia article (AIRC_SCROLL_URL, else the saved copy):
    /// each must answer OK and move the page.
    private func scrollChecks(_ done: @escaping () -> Void) {
        let url = ProcessInfo.processInfo.environment["AIRC_SCROLL_URL"] ?? "\(base)/wiki"
        client.call("open_window", ["url": url, "width": 1280, "height": 800]) { r, _ in
            let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.client.call("wait_for_load", ["window": w], timeout: 40) { _, _ in
                var results: [String] = []
                var moved = 0, failed = 0
                func scrollY(_ then: @escaping (Double) -> Void) {
                    guard let aw = AgentCenter.shared.windows[w], let tab = aw.activeTab else { return then(-1) }
                    aw.driver.evaluate(tab, "JSON.stringify({y: window.scrollY})") { v in then(agentJSON(v)?["y"] as? Double ?? -1) }
                }
                let steps: [[String: Any]] = Array(repeating: ["scroll_direction": "down", "scroll_amount": 5, "coordinate": [640, 400]], count: 5)
                    + [["scroll_direction": "up", "scroll_amount": 3, "coordinate": [640, 400]], ["scroll_direction": "down", "scroll_amount": 3],
                       // Over the left column (Wikipedia's pinned contents at this width).
                       ["scroll_direction": "down", "scroll_amount": 5, "coordinate": [150, 400]],
                       ["scroll_direction": "down", "scroll_amount": 5, "coordinate": [150, 400]]]
                func run(_ i: Int) {
                    guard i < steps.count else {
                        self.note("scroll on \(url.hasPrefix("http://127.") ? "the saved article" : url): " + results.joined(separator: "; "))
                        self.check(failed == 0, "scroll: every scroll on the Wikipedia article answers OK (\(failed) failed of \(steps.count))")
                        self.check(moved == steps.count, "scroll: every scroll moves the page (\(moved) of \(steps.count))")
                        return self.wheelFallback(w, scrollY) { self.client.call("close_window", ["window": w]) { _, _ in done() } }
                    }
                    scrollY { before in
                        var a = steps[i]; a["window"] = w
                        self.client.call("scroll", a, timeout: 30) { r, ms in
                            let err = SpikeMCPClient.isError(r)
                            if err { failed += 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                scrollY { after in
                                    if after != before { moved += 1 }
                                    results.append("\(i + 1): \(err ? "ERROR " + SpikeMCPClient.text(r).prefix(80) : "OK") \(Int(ms)) ms y \(Int(before))→\(Int(after))")
                                    run(i + 1)
                                }
                            }
                        }
                    }
                }
                run(0)
            }
        }
    }

    /// Chromium: a wheel that gets no frame (forced here with a 1 ms limit) still scrolls, from a script.
    private func wheelFallback(_ w: Int, _ scrollY: @escaping (@escaping (Double) -> Void) -> Void, _ done: @escaping () -> Void) {
        #if canImport(AircCore)
        guard engine == "chromium", let driver = AgentCenter.shared.windows[w]?.driver as? ChromiumAgentDriver else { return done() }
        let before = driver.wheelFallbacks
        ChromiumAgentDriver.wheelTimeout = 0.001
        scrollY { y0 in
            self.client.call("scroll", ["window": w, "scroll_direction": "up", "scroll_amount": 4, "coordinate": [640, 400]]) { r, ms in
                ChromiumAgentDriver.wheelTimeout = 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    scrollY { y1 in
                        self.check(!SpikeMCPClient.isError(r) && y1 < y0 && driver.wheelFallbacks > before,
                                   "scroll: a wheel without a frame falls back to a script scroll (forced, \(Int(ms)) ms, y \(Int(y0))→\(Int(y1)))")
                        done()
                    }
                }
            }
        }
        #else
        done()
        #endif
    }

    // MARK: Rules per app

    private func rulesChecks(_ done: @escaping () -> Void) {
        let center = AgentCenter.shared
        guard let key = center.settings.clients.first(where: { $0.key == "airc|name:agentspike-check" })?.key else {
            check(false, "rules: the check's app is remembered"); return done()
        }
        center.setBlockedSites(key, ["127.0.0.1"])
        client.call("open_window", ["url": "\(base)/second.html"]) { r, _ in
            self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("may never open"),
                       "rules: open_window refuses a site on the app's never-open list (\(SpikeMCPClient.text(r).prefix(90)))")
            center.setBlockedSites(key, [])
            self.client.call("open_window", ["url": "\(self.base)/second.html"]) { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                self.check(w != 0, "rules: the site opens once it's off the list")
                // A page already on the site when the rule comes: nothing acts on it.
                center.setBlockedSites(key, ["127.0.0.1"])
                self.client.call("read_page", ["window": w]) { r, _ in
                    self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("Navigate elsewhere"),
                               "rules: read_page refuses a page that is on a never-open site")
                    self.client.call("navigate", ["window": w, "url": "\(self.base)/agent.html"]) { r, _ in
                        self.check(SpikeMCPClient.isError(r), "rules: navigate refuses a never-open site")
                        center.setBlockedSites(key, [])
                        // The Airc Agent's global "never use" list closes the site to every app.
                        let before = AgentModelSettings.shared.values.blockedSites
                        AgentModelSettings.shared.update { $0.blockedSites = ["127.0.0.1"] }
                        self.client.call("navigate", ["window": w, "url": "\(self.base)/agent.html"]) { r, _ in
                            self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("never use"),
                                       "rules: the global never-use list (Settings › AI) applies to apps too")
                            AgentModelSettings.shared.update { $0.blockedSites = before }
                            self.client.call("close_window", ["window": w]) { _, _ in self.profileRule(key, done) }
                        }
                    }
                }
            }
        }
    }

    private func profileRule(_ key: String, _ done: @escaping () -> Void) {
        let center = AgentCenter.shared
        let other = app.store.defaultProfile
        center.setProfileRule(key, other.id)
        client.call("use_profile", ["profile": "Agent"]) { r, _ in
            self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("may only use"),
                       "rules: use_profile refuses a profile other than the app's (\(SpikeMCPClient.text(r).prefix(80)))")
            self.client.call("list_profiles") { r, _ in
                let names = ((SpikeMCPClient.json(r)["profiles"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                self.check(names == [other.name], "rules: list_profiles shows only the app's profile (\(names))")
                let asking = self.helper("Agent")
                self.extra.append(asking)
                self.connect(asking, answer: nil) { ok, asked in
                    self.check(!ok && asked == nil && asking.stderrText.contains("may only use"),
                               "rules: a connection asking for another profile is refused, without a question")
                    center.setProfileRule(key, nil)
                    self.client.call("use_profile", ["profile": "Agent"]) { r, _ in
                        self.check(!SpikeMCPClient.isError(r), "rules: with the rule cleared, the app may use Agent again")
                        done()
                    }
                }
            }
        }
    }

    // MARK: Files

    private func fileChecks(_ done: @escaping () -> Void) {
        let center = AgentCenter.shared
        if DownloadCenter.agentClaim == nil {
            DownloadCenter.agentClaim = { d, p in AgentCenter.shared.claimDownload(d, profileID: p) }
        }
        client.call("list_downloads") { r, _ in
            guard let folder = SpikeMCPClient.json(r)["folder"] as? String else {
                self.check(false, "files: list_downloads names the app's folder"); return done()
            }
            self.check(folder.hasPrefix(AppPaths.dataDirectory.path), "files: the app's folder (scripted runs: in the data folder) \(folder)")
            let mine = URL(fileURLWithPath: folder).appendingPathComponent("upload-me.txt")
            try? Data("twelve bytes".utf8).write(to: mine)
            let link = URL(fileURLWithPath: folder).appendingPathComponent("escape.txt")
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
            let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("airc-uploads-\(getpid())", isDirectory: true)
            try? FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
            let picked = chosen.appendingPathComponent("chosen.txt")
            try? Data("five!".utf8).write(to: picked)
            self.client.call("open_window", ["url": "\(self.base)/upload"]) { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                self.client.call("upload_file", ["window": w, "path": "/etc/hosts", "coordinate": [100, 60]]) { r, _ in
                    self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("only uploads files from"),
                               "files: upload_file refuses a path outside the allowed folders")
                    self.client.call("upload_file", ["window": w, "path": link.path, "coordinate": [100, 60]]) { r, _ in
                        self.check(SpikeMCPClient.isError(r), "files: a symlink out of the app's folder is refused")
                        self.client.call("upload_file", ["window": w, "path": picked.path, "coordinate": [100, 60]]) { r, _ in
                            self.check(SpikeMCPClient.isError(r), "files: a folder the person didn't choose is refused")
                            self.client.call("upload_file", ["window": w, "path": mine.path, "coordinate": [100, 60]]) { r, _ in
                                self.check(!SpikeMCPClient.isError(r), "files: upload_file takes a file from the app's folder (\(SpikeMCPClient.text(r).prefix(90)))")
                                self.pageText(w) { t in
                                    self.check(t.contains("picked upload-me.txt:12"), "files: the page's file field got it (\(t.prefix(60)))")
                                    center.setUploadFolder(chosen.path)
                                    self.client.call("upload_file", ["window": w, "path": picked.path]) { r, _ in
                                        self.pageText(w) { t in
                                            self.check(!SpikeMCPClient.isError(r) && t.contains("picked chosen.txt:5"),
                                                       "files: a file in the chosen upload folder, to the page's only file field (\(t.prefix(60)))")
                                            center.setUploadFolder(nil)
                                            try? FileManager.default.removeItem(at: chosen)
                                            self.client.call("close_window", ["window": w]) { _, _ in self.downloadCheck(folder, done) }
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

    private func pageText(_ w: Int, _ then: @escaping (String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.client.call("read_page", ["window": w]) { r, _ in then(SpikeMCPClient.text(r)) }
        }
    }

    private func downloadCheck(_ folder: String, _ done: @escaping () -> Void) {
        client.call("open_window", ["url": "\(base)/dl"]) { r, _ in
            let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.client.call("left_click", ["window": w, "coordinate": [90, 60]]) { _, _ in
                let file = URL(fileURLWithPath: folder).appendingPathComponent("agent-file.txt").path
                self.poll({ FileManager.default.fileExists(atPath: file) }, timeout: 10) { landed in
                    self.check(landed, "files: an agent page's download lands in the app's folder")
                    self.client.call("list_downloads") { r, _ in
                        let files = (SpikeMCPClient.json(r)["files"] as? [[String: Any]]) ?? []
                        self.check(files.contains { $0["path"] as? String == file }, "files: list_downloads returns its path")
                        let person = MediaLibrary.shared.downloads?.items.contains { $0.download.fileName.hasPrefix("agent-file") } ?? false
                        self.check(!person, "files: the person's Downloads list doesn't show the agent's download")
                        self.client.call("close_window", ["window": w]) { _, _ in done() }
                    }
                }
            }
        }
    }

    // MARK: Real input (FG runs: AIRC_REAL_KEYS=1, the UI driver's clicks and keys)

    private func driverClick(_ v: NSView?, _ what: String, _ then: @escaping (Bool) -> Void) {
        guard let v, let w = v.window, let primary = NSScreen.screens.first else { check(false, "[real] \(what): on screen"); return then(false) }
        v.scrollToVisible(v.bounds)
        let g = w.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
        UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
            if !ok { self.note("FAIL-ENV [real click] \(what): \(out)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then(ok) }
        }
    }

    private func driverKeys(_ keys: [String], _ then: @escaping () -> Void) {
        guard let k = keys.first else { return then() }
        UIDriverClient.run(["--key", k, "--pid", "\(getpid())"]) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.driverKeys(Array(keys.dropFirst()), then) }
        }
    }

    private func realInputChecks(_ done: @escaping () -> Void) {
        let center = AgentCenter.shared
        let key = "airc|name:agentspike-check"
        let before = activations
        let finished = done
        // A person clicking in Settings makes Airc active; that's this step's, not an agent's (finish() counts it apart).
        let done = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.deliberateActivations += self.activations - before
            NSApp.deactivate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: finished)
        } }
        NSApp.activate(ignoringOtherApps: true)
        app.showSettings(page: .agents)
        guard let sw = app.settingsWindow?.window else { check(false, "[real] Settings opens"); return done() }
        sw.setContentSize(NSSize(width: 780, height: 900))
        sw.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let button = sw.contentView.flatMap { TestAnchors.view("agents.rules.agentspike-check", in: $0) }
            self.driverClick(button, "Rules…") { _ in
                // The popover is its own window with the field in it.
                let field = NSApp.windows.compactMap { $0.contentView.flatMap { TestAnchors.view("agents.rules.site", in: $0) } }.first
                self.check(field != nil, "[real] Rules… opens the app's rules (a real click)")
                self.driverClick(field, "the never-open field") { _ in
                    self.driverKeys("example.org".map { String($0) } + ["return"]) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let sites = center.client(key)?.blockedSites ?? []
                            self.check(sites.contains("example.org"), "[real] a site typed into the rules is kept (\(sites))")
                            self.client.call("open_window", ["url": "https://example.org/"]) { r, _ in
                                self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("may never open"),
                                           "[real] the typed rule is enforced: open_window refuses example.org")
                                center.setBlockedSites(key, [])
                                self.driverKeys(["esc"]) {
                                    sw.close()
                                    self.realNeedsYouRow(done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A client in the person's profile lands on the sign-in page: its row shows in the person's window with the
    /// folder's badge; a real click on the row opens Watch.
    private func realNeedsYouRow(_ done: @escaping () -> Void) {
        let d = helper(app.store.defaultProfile.name)
        extra.append(d)
        connect(d, answer: nil) { ok, _ in
            guard ok else { self.check(false, "[real] the person's-profile client connects"); return done() }
            d.call("open_window", ["url": "\(self.base)/login"]) { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                d.call("wait_for_load", ["window": w]) { _, _ in
                    guard let c = self.runner.c else { return done() }
                    c.window.makeKeyAndOrderFront(nil)
                    let row = AgentActivity.shared.model.rows.first { $0.window == w && $0.isLive }
                    self.poll({ TestAnchors.view("agents-needs-you", in: c.sidebar) != nil }, timeout: 4) { badge in
                        self.check(row?.needsYou == "Sign in" && badge, "[real] the person's window shows the Needs you badge (row \(row?.needsYou ?? "none"))")
                        let rowView = row.flatMap { TestAnchors.view("agents-title-\($0.id)", in: c.sidebar) }
                        self.driverClick(rowView, "the Needs you row") { _ in
                            self.check(row.map { AgentActivity.shared.isWatched($0.id) } ?? false, "[real] clicking the Needs you row opens Watch on its page")
                            d.call("close_window", ["window": w]) { _, _ in d.stop(); done() }
                        }
                    }
                }
            }
        }
    }

    // MARK: Needs you

    private func needsYouChecks(_ done: @escaping () -> Void) {
        AgentNeedsYou.delay = 1
        var events: [String] = []
        let previous = AgentCenter.shared.onEvent
        AgentCenter.shared.onEvent = { e in events.append(e); previous?(e) }
        func row(_ w: Int) -> AgentTabRow? { AgentActivity.shared.model.rows.first { $0.window == w && $0.isLive } }
        client.call("open_window", ["url": "\(base)/second.html"]) { r, _ in
            let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.client.call("navigate", ["window": w, "url": "\(self.base)/login"]) { r, _ in
                let j = SpikeMCPClient.json(r)
                self.check(j["needsYou"] as? String == "Sign in" && (j["note"] as? String ?? "").contains("waits for the person"),
                           "needs you: navigate to a sign-in page says it waits for the person (\(j["needsYou"] ?? "nothing"))")
                self.check(row(w)?.needsYou == "Sign in" && AgentActivity.shared.model.needsYouCount >= 1,
                           "needs you: the Agents row is marked (\(row(w)?.needsYou ?? "no"))")
                // Once the agent's acting tail is over (acting wins while it works).
                let later = Date().addingTimeInterval(AgentActivityModel.actingTail + 0.1)
                if case .needsYou = AgentActivity.shared.model.state(row(w) ?? AgentTabRow(id: "", sessionKey: "", clientKey: nil, client: "", profileID: "", window: 0, tab: 0, started: Date()), now: later) {
                    self.check(true, "needs you: the row's state reads Needs you")
                } else { self.check(false, "needs you: the row's state reads Needs you") }
                self.client.call("screenshot", ["window": w]) { r, _ in
                    self.check(SpikeMCPClient.text(r).contains("waits for the person"), "needs you: a screenshot result carries the note too")
                    self.poll({ events.contains { $0.hasPrefix("needs-you-notified") } }, timeout: 4) { notified in
                        self.check(notified, "needs you: the notification step fires after the delay")
                        let badge = self.runner.c.map { TestAnchors.view("agents-needs-you", in: $0.sidebar) != nil } ?? false
                        self.note("needs you: folder badge on screen: \(badge) (the person's window shows the Agent profile's folder only when it is that profile)")
                        self.client.call("navigate", ["window": w, "url": "\(self.base)/second.html"]) { r, _ in
                            self.check(SpikeMCPClient.json(r)["needsYou"] == nil && row(w)?.needsYou == nil,
                                       "needs you: a normal page clears it")
                            self.client.call("navigate", ["window": w, "url": "\(self.base)/captcha"]) { r, _ in
                                self.check(SpikeMCPClient.json(r)["needsYou"] as? String == "Captcha", "needs you: a captcha page is marked Captcha")
                                self.client.call("navigate", ["window": w, "url": "\(self.base)/denied"]) { r, _ in
                                    let got = SpikeMCPClient.json(r)["needsYou"] as? String
                                    if self.engine == "chromium" {
                                        self.check(got == "Sign in", "needs you: a 401 page is marked Sign in (\(got ?? "nothing"))")
                                    } else {
                                        self.note("needs you: WebKit 401 → \(got ?? "nothing") (responseStatus support varies)")
                                    }
                                    AgentNeedsYou.delay = 8
                                    AgentCenter.shared.onEvent = previous
                                    self.client.call("close_window", ["window": w]) { _, _ in done() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

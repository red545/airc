// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// `--script boostsync-a`, `-b`, `-a2`, `-b2` (docs/sync.md, "Boosts" and "Archive timing"), both engines: Boosts and
/// archive timing between two app instances through a mock CloudKit database in a shared folder (`--sync-mock`), each
/// with its own fake keychain (`--sync-keychain`; a copied key file plays iCloud Keychain). Never the real iCloud or
/// keychain. Pages come from a loopback server (127.0.0.1, its own port in each launch). Synthetic values only.
///
/// - `boostsync-a`: Mac A turns sync on, makes a Boost for 127.0.0.1 (a tint, CSS, JavaScript) whose code runs on its page,
///   and pins a tab. What went up: the Boost in a version 5 batch only, nothing of it readable.
/// - `boostsync-b`: Mac B merges. The Boost arrives: its CSS shows on B's page at once, its code doesn't run. The editor
///   shows the one-click confirm naming Mac A (boostsync-confirm.png); Run on This Mac (the model's action) reloads the
///   page and the code runs. A Boost whose code no Mac vouched for shows the full review: Run only after Show Code
///   (boostsync-review.png). B opens the pinned tab (its own last use), then shows another tab.
/// - `boostsync-a2`: Mac A uses the pinned tab (later than B did), unpins it, and syncs: the last use goes up in a
///   version 5 batch, the unpin in a version 1 batch.
/// - `boostsync-b2`: Mac B syncs: the pinned tab's page is a Today tab now, and its archive timer continues from A's
///   later use, not from B's own.
/// The loopback server lives for the whole launch: LocalPageServer serves through a weak reference, so a server only
/// a finished step captured would be gone before the page asks for it.
private enum BoostSyncServer { static var current: LocalPageServer? }

extension SnapshotRunner {
    func boostSyncScenario() {
        let sync = SyncCenter.shared
        let args = ProcessInfo.processInfo.arguments
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        func folder(_ name: String) -> URL? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
        }
        guard let mock = folder("--sync-mock"), let keychain = folder("--sync-keychain") else {
            note("FAIL \(script): needs --sync-mock and --sync-keychain")
            return
        }
        let firstKeychain = keychain.deletingLastPathComponent().appendingPathComponent("keychain-a", isDirectory: true)
        let shared = mock.deletingLastPathComponent()
        let database = try? SyncFolderCloudDatabase(folder: mock)
        let site = "127.0.0.1"
        let code = "document.documentElement.dataset.boostsync = 'ran';"
        let css = "#hero { color: rgb(1, 2, 3) !important; }"
        let pinnedURL = "http://127.0.0.1:9/boostsync-archive"
        let macA = "Boost Mac a"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let center = { BoostCenter.shared }
        let editor = { self.c.boostEditor?.model }
        func say(_ ok: Bool, _ what: String) { check(ok, "\(script) (\(tag)): " + what) }

        func batches() -> [SyncEnvelope] {
            ((try? database?.withState { $0 })?.records(zone: SyncCloudSchema.zone) ?? []).compactMap(SyncCloudSchema.envelope)
        }
        /// Every operation in iCloud with its batch's version, opened with the group key from A's keychain.
        func ops() -> [(version: Int, op: SyncOperation)] {
            guard let state = try? database?.withState({ $0 }),
                  let group = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.group).first,
                  let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else { return [] }
            return batches().flatMap { e in ((try? e.open(group: group.group, key: key)) ?? []).map { (e.version, $0) } }
        }
        func waitFor(_ what: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script) (\(tag)): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        func startServer() {
            step { [self] done in
                let body = "<!doctype html><html><head><title>boostsync</title><link rel=\"icon\" href=\"data:,\">"
                    + "<style>#hero { color: rgb(10, 20, 30) }</style></head><body><h1 id=\"hero\">Boost sync</h1></body></html>"
                server = LocalPageServer(responses: ["/boost": .init(body: body)])
                BoostSyncServer.current = server
                guard let server else { say(false, "the loopback server starts"); return done() }
                server.start { p in
                    if let p { port = p } else { self.check(false, "\(self.script) (\(tag)): the loopback server starts") }
                    done()
                }
            }
        }
        func waitPage() {
            step { [self] done in
                waitUntil({ page()?.title == "boostsync" && page()?.isLoading == false }, timeout: 10) {
                    if page()?.title != "boostsync" {
                        self.check(false, "\(self.script) (\(tag)): the Boost's page loads (\(page()?.url?.absoluteString ?? "no page"), title \(page()?.title ?? "-"))")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
                }
            }
        }
        func openPage() {
            run { [self] in
                guard port != 0, let t = try? c.store.openTab(url: "http://\(site):\(port)/boost", inSpace: c.currentSpaceID, title: "boostsync")
                else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            waitPage()
        }
        /// The page's hero colour (the Boost's CSS) and whether the Boost's code ran there.
        func probe(_ then: @escaping (_ color: String, _ ran: String) -> Void) {
            step { done in
                guard let p = page() else { then("no page", "no page"); return done() }
                p.evaluate("getComputedStyle(document.getElementById('hero')).color + '|' + (document.documentElement.dataset.boostsync || 'none')") { v in
                    let parts = (v.map { "\($0)" } ?? "nil|nil").split(separator: "|").map(String.init)
                    then(parts.first ?? "nil", parts.count > 1 ? parts[1] : "nil")
                    done()
                }
            }
        }
        /// When B last used the pinned tab, kept between B's launches.
        let markFile = shared.appendingPathComponent("boostsync-b-use.txt")

        switch script {
        case "boostsync-a":
            startServer()
            run { [self] in
                say(sync.isAvailable && !sync.isEnabled && sync.syncsBoosts, "sync off at first, Sync Boosts on by default")
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            run { [self] in
                center()?.update(domain: site) { $0.colors.tint = 0.4; $0.css = css; $0.js = code }
                // A pinned tab B will use, and A later unpins (boostsync-a2).
                if let t = try? c.store.openTab(url: pinnedURL, inSpace: c.currentSpaceID, title: "Archive doc") {
                    try? c.store.togglePin(t.id, inSpace: c.currentSpaceID)
                }
            }
            openPage()
            probe { [self] color, ran in
                say(color == "rgb(1, 2, 3)" && ran == "ran", "A's own Boost: its CSS and code apply on its page (\(color), \(ran))")
            }
            run { sync.syncNow() }
            waitFor("the Boost in iCloud") { ops().contains { $0.op.record.kind == .boost } }
            run { [self] in
                let mine = ops().filter { $0.op.record.kind == .boost }
                say(mine.allSatisfy { $0.version == SyncBoosts.envelopeVersion } && mine.contains { $0.op.record.id == site },
                    "the Boost went up in version 5 batches only (\(Set(mine.map(\.version)).sorted()))")
                if case .boost(let p)? = mine.last?.op.fields[.value] {
                    say(p.allowedOn == macA && p.js == code, "it says the code is allowed on \(p.allowedOn ?? "no Mac")")
                }
                let raw = (try? database?.withState { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }) ?? ""
                say(!["boostsync", "rgb(1, 2, 3)", "dataset"].contains(where: raw.contains), "nothing of the Boost is readable in iCloud")
            }

        case "boostsync-b":
            startServer()
            run { [self] in
                let fm = FileManager.default
                try? fm.createDirectory(at: keychain, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: firstKeychain, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.copyItem(at: file, to: keychain.appendingPathComponent(file.lastPathComponent))
                }
                // The first sync backs up into a folder that exists (the default, in this run's data folder).
                sync.setEnabled(true)
            }
            waitFor("the first-sync screen or up to date") { sync.firstSync != nil || sync.status == .upToDate }
            run { [self] in
                if sync.firstSync != nil {
                    sync.choose(.merge, profiles: [:]) { [self] error in if let error { note("FAIL \(script) (\(tag)): Merge failed: \(error)") } }
                }
            }
            waitFor("up to date after Merge") { sync.status == .upToDate }
            waitFor("A's Boost here", timeout: 20) { center()?.store.boost(domain: site) != nil }
            run { [self] in
                let b = center()?.store.boost(domain: site)
                say(b?.css == css && b?.colors.tint == 0.4, "A's Boost arrived: its tint and CSS")
                say(b?.js == "" && b?.heldCode?.js == code && b?.heldCode?.allowedOn == macA,
                    "its code waits, naming the Mac it was allowed on (\(b?.heldCode?.allowedOn ?? "none"))")
            }
            openPage()
            probe { [self] color, ran in
                say(color == "rgb(1, 2, 3)", "its CSS shows on B's page at once (\(color))")
                say(ran == "none", "its code didn't run on B (\(ran))")
            }
            run { [self] in c.showBoostEditor() }
            waitFor("the editor", timeout: 5) { editor()?.syncedCode != nil }
            run { [self] in
                let m = editor()
                say(m?.syncedCode?.allowedOn == macA && m?.canAllowSyncedCode == true && m?.showsSyncedCode == false,
                    "the editor shows the one-click confirm naming \(macA), without showing the code first")
            }
            capture("boostsync-confirm")
            run { [self] in editor()?.allowSyncedCode() }
            // The page loads again (the code runs once per page load).
            step { done in DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done) }
            waitPage()
            probe { [self] color, ran in say(ran == "ran" && color == "rgb(1, 2, 3)", "Run on This Mac: the page loaded again and the code ran (\(ran))") }
            run { [self] in
                let b = center()?.store.boost(domain: site)
                say(b?.heldCode == nil && b?.js == code, "the code is allowed on this Mac now")
                // A Boost whose code no Mac vouched for: the full review (Run only after Show Code).
                let unvouched = BoostSyncPayload(changed: 1_000, css: "body { margin: 0 }", js: "console.log('unvouched')")
                _ = center()?.applySynced(["localhost": unvouched])
                c.showBoostEditor(domain: "localhost")
            }
            waitFor("the review", timeout: 5) { editor()?.domain == "localhost" && editor()?.syncedCode != nil }
            run { [self] in
                say(editor()?.syncedCode?.allowedOn == nil && editor()?.canAllowSyncedCode == false, "no Mac vouched: Run waits until the code is shown")
                editor()?.allowSyncedCode()
                say(center()?.store.boost(domain: "localhost")?.heldCode != nil, "nothing ran without the review")
                editor()?.showsSyncedCode = true
            }
            capture("boostsync-review")
            run { [self] in
                say(editor()?.canAllowSyncedCode == true, "after Show Code, Run on This Mac is there")
                _ = c.closeBoostEditor(animated: false)
                center()?.remove(domain: "localhost", page: nil)
                // B uses the pinned tab now, then shows another tab (so a relaunch doesn't show it again).
                guard let item = c.store.state.items.values.first(where: { $0.savedURL == pinnedURL }), let space = item.spaceID,
                      let t = try? c.store.openItem(item.id, inSpace: space) else { return say(false, "the pinned tab arrived") }
                c.show(t.id, focus: false)
                let used = c.store.tab(t.id)?.lastActiveAt ?? .distantPast
                try? "\(used.timeIntervalSince1970)\n\(t.id)".write(to: markFile, atomically: true, encoding: .utf8)
                say(true, "B used the pinned tab at \(used)")
                if let other = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, title: "other") { c.show(other.id, focus: false) }
                sync.syncNow()
            }
            waitFor("up to date", timeout: 20) { sync.status == .upToDate }

        case "boostsync-a2":
            run { [self] in
                // Later than B's use: A uses the pinned tab, then unpins it.
                guard let item = c.store.state.items.values.first(where: { $0.savedURL == pinnedURL }), let space = item.spaceID,
                      let t = c.store.liveTab(forItem: item.id) ?? (try? c.store.openItem(item.id, inSpace: space)) else {
                    return say(false, "A has the pinned tab")
                }
                c.show(t.id, focus: false)
                try? c.store.togglePin(t.id, inSpace: space)
                say(c.store.tab(t.id)?.isToday == true, "A unpinned it: its page is a Today tab here")
                sync.syncNow()
            }
            waitFor("A's last use in iCloud") { ops().contains { $0.op.fields[.used] != nil } }
            run { [self] in
                let uses = ops().filter { $0.op.fields[.used] != nil }
                say(uses.allSatisfy { $0.version == SyncBoosts.envelopeVersion }, "the last use went up in a version 5 batch only")
                say(ops().contains { $0.version == 1 && $0.op.fields[.location] == .location(.archived) },
                    "the unpin itself went up in a version 1 batch (older builds read it)")
            }

        case "boostsync-b2":
            let mark = (try? String(contentsOf: markFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let bUse = mark.first.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let tab = mark.count > 1 ? mark[1] : ""
            run { sync.syncNow() }
            waitFor("the unpinned tab in Today here", timeout: 30) { [self] in c.store.tab(tab)?.isToday == true }
            run { [self] in
                var aUse: Date?
                for (_, op) in ops() {
                    guard case .time(let ms)? = op.fields[.used] else { continue }
                    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
                    if aUse.map({ d > $0 }) ?? true { aUse = d }
                }
                let t = c.store.tab(tab)
                guard let t, let aUse, let bUse else { return say(false, "B's tab, A's use and B's use are known (\(t != nil), \(aUse != nil), \(bUse != nil))") }
                say(aUse > bUse, "A used it after B did (\(aUse) > \(bUse))")
                say(abs(t.lastActiveAt.timeIntervalSince(aUse)) < 0.01,
                    "its archive timer continues from A's later use (\(t.lastActiveAt)), not from B's (\(bUse))")
                let after = c.store.profile(t.profileID)?.archiveAfter.seconds ?? 0
                let due = c.store.dueForAutoArchive().contains(tab)
                say(!due, "not archived early (due in \(Int(aUse.addingTimeInterval(after).timeIntervalSinceNow)) s)")
                try? FileManager.default.removeItem(at: markFile)
            }

        default:
            note("FAIL unknown script \(script)")
        }
    }
}
#endif

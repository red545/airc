// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import Compression

/// `--script paritysharing` (both engines): hosted sharing (H01, H02, B03; docs/dev/sharing-service.md) against a local
/// sharing server (apps/marketing/scripts/sharing-dev.mjs, the same functions as aircbrowser.com with an in-memory
/// store) or a Preview deployment: AIRC_SHARING_BASE (+ AIRC_SHARING_BYPASS, AIRC_SHARING_ADMIN). Never Production.
///   - Share Space…, Share Folder…, Share This Space…; the preview shows exactly the pinned tree and what's left out, and
///     nothing is published before Create Link;
///   - Create Link publishes, the link is copied, its key is held (not in the records file), the server has exactly the
///     snapshot;
///   - the link opened from another app (https and airc://share/<id>) and from a tab shows the import preview; Add makes
///     the same tree in the chosen destination (another Space for a folder), unloaded, one ⌘Z;
///   - Take Back: the link 404s, opening it says so and adds nothing;
///   - unsafe addresses are refused by the service, and fragment links that are damaged, newer, unsafe or zip bombs are
///     refused whole (P17a's cases);
///   - the gallery: Submit to the Gallery queues a Boost, the owner approves it (the admin page), it's listed in File ›
///     Boost Gallery with Airc's own, Get opens the review, Report sends a report; offline, Airc's own remain.
extension SnapshotRunner {
    func paritySharingScenario() {
        let center = SharingCenter.shared
        let base = center.service.base
        guard base.host != "aircbrowser.com", base.host != "www.aircbrowser.com" else {
            run { [self] in check(false, "paritysharing: set AIRC_SHARING_BASE to a local server or a Preview (never Production)") }
            return
        }
        var sid = "", otherSid = "", folderID = "", noteless = 0
        var board: NSPasteboard?, oldBoard: NSPasteboard?
        var spaceLink: SharedLinkRecord?, folderLink: SharedLinkRecord?
        run { [self] in
            oldBoard = WindowController.linkPasteboard
            board = NSPasteboard(name: .init("org.airc.paritysharing.\(UUID().uuidString)"))
            WindowController.linkPasteboard = board!
            let profile = c.store.profile(ofSpace: c.currentSpaceID).id
            guard let s = try? c.store.createSpace(name: "Lisbon Trip", icon: .emoji("🧳"), profileID: profile, after: c.currentSpaceID),
                  let o = try? c.store.createSpace(name: "Reading Room", icon: nil, profileID: profile, after: s.id)
            else { return check(false, "paritysharing: Spaces to share") }
            sid = s.id
            otherSid = o.id
            func pin(_ url: String, parent: String? = nil) {
                guard let t = try? c.store.openTab(url: url, inSpace: sid, title: "") else { return }
                _ = try? c.store.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: parent, index: 99))
            }
            pin("https://www.visitlisboa.example/")
            folderID = (try? c.store.createFolder(named: "Food", inSpace: sid))?.id ?? ""
            pin("https://pasteis.example/menu", parent: folderID)
            pin("https://tram28.example/route", parent: folderID)
            pin("airc-note:shopping-list")
            _ = try? c.store.openTab(url: "https://today.example/", inSpace: sid)
            noteless = 3
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
        }
        wait(0.5)

        // The menus and the Command Bar.
        run { [self] in
            let spaceTitles = c.spaceMenu(spaceID: sid).items.map(\.title)
            let folder = c.store.item(folderID).map { c.menu(for: .folder($0, depth: 0)).items.map(\.title) } ?? []
            check(spaceTitles.contains("Share Space…") && folder.contains("Share Folder…") && c.shareCommandActions().map(\.title) == ["Share This Space…"],
                  "paritysharing: Share Space… in the Space menu, Share Folder… in the folder menu, Share This Space… in the Command Bar")
        }

        // Share Space…: the preview; nothing is published before Create Link.
        run { [self] in
            let menu = c.spaceMenu(spaceID: sid)
            if let i = menu.items.firstIndex(where: { $0.title == "Share Space…" }) { menu.performActionForItem(at: i) }
            guard let sheet = ShareLinkSheet.active[ObjectIdentifier(c.window)] else { return check(false, "paritysharing: Share Space… shows its preview") }
            let counts = sheet.draft.snapshot.counts
            check(counts.tabs == noteless && counts.folders == 1 && sheet.draft.todayTabs == 1 && sheet.draft.leftOut == 1 && sheet.problem == nil
                  && sheet.rows.map(\.title) == ["www.visitlisboa.example", "Food", "pasteis.example", "tram28.example"]
                  && sheet.phase == .preview && center.links(of: sid).isEmpty,
                  "paritysharing: the preview shows the pinned tree only and what's left out, nothing published yet (\(sheet.leftOutText))")
            sheet.create()
        }
        step { [self] done in waitUntil({ ShareLinkSheet.active[ObjectIdentifier(self.c.window)]?.published != nil }, timeout: 15) {
            guard let sheet = ShareLinkSheet.active[ObjectIdentifier(self.c.window)], let r = sheet.published else {
                self.check(false, "paritysharing: Create Link publishes (\(ShareLinkSheet.active[ObjectIdentifier(self.c.window)]?.message ?? "no answer"))")
                return done()
            }
            spaceLink = r
            let onDisk = (try? String(contentsOf: SharingCenter.file, encoding: .utf8)) ?? ""
            self.check(r.url.path == "/s/\(r.id)" && r.url.host == base.host && center.holdsToken(for: r.id) && onDisk.contains(r.id)
                       && !onDisk.lowercased().contains("token") && center.links(of: self.c.currentSpaceID).map(\.id) == [r.id],
                       "paritysharing: Create Link publishes \(r.url.absoluteString); its key is held, the records file has no key")
            sheet.copyLink()
            self.check(ShareLinkSheet.active[ObjectIdentifier(self.c.window)] == nil && board?.string(forType: .string) == r.url.absoluteString
                       && self.c.toast.shownText == "Copied Link", "paritysharing: Copy Link puts the link on the clipboard, with a toast")
            done()
        } }
        step { [self] done in
            Task { @MainActor in
                let original = c.store.shareDraft(ofSpace: sid)?.snapshot
                let served = try? await center.service.snapshot(id: spaceLink?.id ?? "")
                check(served != nil && served == original, "paritysharing: the server holds exactly the snapshot that was shown")
                done()
            }
        }

        // Opened from another app: the preview, Cancel adds nothing, Add as New Space adds the same tree; ⌘Z.
        var before = 0
        run { [self] in
            guard let r = spaceLink, let app else { return }
            before = c.store.orderedSpaces.count
            app.routeExternal(r.url)
        }
        step { [self] done in waitUntil({ ShareImportSheet.active[ObjectIdentifier(self.c.window)] != nil }, timeout: 10) {
            guard let sheet = ShareImportSheet.active[ObjectIdentifier(self.c.window)] else {
                self.check(false, "paritysharing: a hosted link from another app shows the import preview (\(ShareLinkImport.lastError ?? "nothing"))")
                return done()
            }
            self.check(sheet.isSpace && sheet.snapshot.name == "Lisbon Trip" && sheet.rows.count == 4 && sheet.destinations.count >= 1,
                       "paritysharing: a hosted link from another app shows what it holds (\(ShareRow.summary(sheet.snapshot)))")
            sheet.close()
            self.check(self.c.store.orderedSpaces.count == before, "paritysharing: Cancel adds nothing")
            done()
        } }
        run { [self] in
            guard let r = spaceLink, let app, let appURL = HostedShareLink.appURL(id: r.id) else { return }
            app.routeExternal(appURL)
        }
        step { [self] done in waitUntil({ ShareImportSheet.active[ObjectIdentifier(self.c.window)] != nil }, timeout: 10) {
            guard let sheet = ShareImportSheet.active[ObjectIdentifier(self.c.window)] else {
                self.check(false, "paritysharing: the page's airc://share/<id> opens the import preview")
                return done()
            }
            let original = self.c.store.shareDraft(ofSpace: sid)?.snapshot
            sheet.add()
            let added = self.c.store.orderedSpaces.first { $0.name == "Lisbon Trip" && $0.id != sid }
            self.check(self.c.store.orderedSpaces.count == before + 1 && added.map { self.c.store.shareDraft(ofSpace: $0.id)?.snapshot } == original
                       && added.map { self.c.store.todayTabs(ofSpace: $0.id).isEmpty } == true && self.c.currentSpaceID == added?.id,
                       "paritysharing: airc://share/<id> → Add as New Space makes the same tree, unloaded, and shows it")
            self.c.switchToSpace(sid, animated: false)
            _ = try? self.c.store.undo()
            self.check(self.c.store.orderedSpaces.count == before, "paritysharing: ⌘Z takes the added Space away")
            done()
        } }

        // Share Folder…, then the folder link into another Space (the chosen destination).
        run { [self] in
            c.shareFolder(folderID)
            ShareLinkSheet.active[ObjectIdentifier(c.window)]?.create()
        }
        step { [self] done in waitUntil({ ShareLinkSheet.active[ObjectIdentifier(self.c.window)]?.published != nil }, timeout: 15) {
            let sheet = ShareLinkSheet.active[ObjectIdentifier(self.c.window)]
            folderLink = sheet?.published
            self.check(folderLink != nil && sheet?.isSpace == false, "paritysharing: Share Folder… → Create Link publishes the folder")
            sheet?.close()
            if let r = folderLink { self.app?.routeExternal(r.url) }
            done()
        } }
        step { [self] done in waitUntil({ ShareImportSheet.active[ObjectIdentifier(self.c.window)] != nil }, timeout: 10) {
            guard let sheet = ShareImportSheet.active[ObjectIdentifier(self.c.window)], !sheet.isSpace else {
                self.check(false, "paritysharing: a folder link shows the import preview")
                return done()
            }
            let draft = self.c.store.shareDraft(ofFolder: folderID)
            let pinned = self.c.store.children(of: .pinned(spaceID: otherSid), parent: nil).count
            sheet.destination = otherSid
            sheet.add()
            let last = self.c.store.children(of: .pinned(spaceID: otherSid), parent: nil).last
            self.check(sheet.destinations.contains { $0.id == otherSid } && self.c.store.children(of: .pinned(spaceID: otherSid), parent: nil).count == pinned + 1
                       && last?.kind == .folder && last.map { self.c.store.shareDraft(ofFolder: $0.id)?.snapshot.items } == draft?.snapshot.items
                       && self.c.currentSpaceID == otherSid,
                       "paritysharing: a folder link adds the folder to the chosen Space (“Reading Room”), order and nesting kept")
            self.c.switchToSpace(sid, animated: false)
            done()
        } }

        // A tab that goes to a hosted link: the preview, once.
        run { [self] in
            guard let r = folderLink else { return }
            ShareLinkImport.shown.removeAll()
            c.openExternal(r.url, inSpace: sid)
        }
        step { [self] done in waitUntil({ ShareImportSheet.active[ObjectIdentifier(self.c.window)] != nil }, timeout: 15) {
            let sheet = ShareImportSheet.active[ObjectIdentifier(self.c.window)]
            self.check(sheet?.snapshot.name == "Food", "paritysharing: a tab going to a hosted link shows its import preview")
            sheet?.close()
            if let r = folderLink {
                let first = ShareLinkImport.firstTime(r.url, in: 99), again = ShareLinkImport.firstTime(r.url, in: 99)
                let page = ShareLinkImport.firstTime(URL(string: "https://example.com/s/Ab3dEf6hIj9K")!, in: 99)
                self.check(first && !again && !page, "paritysharing: the preview shows once per link and tab, never for other sites' /s/ pages")
            }
            done()
        } }

        // Take Back: the link 404s everywhere; opening it says so and adds nothing.
        run { [self] in
            c.shareSpace(sid)
            guard let sheet = ShareLinkSheet.active[ObjectIdentifier(c.window)], let r = spaceLink else { return check(false, "paritysharing: Share Space… again") }
            check(sheet.earlier.map(\.id) == [r.id], "paritysharing: Share Space… lists the link made earlier, with Take Back")
            sheet.takeBack(r, confirmed: true)
        }
        step { [self] done in waitUntil({ !center.records.contains { $0.id == spaceLink?.id } }, timeout: 15) {
            let sheet = ShareLinkSheet.active[ObjectIdentifier(self.c.window)]
            self.check(sheet?.earlier.isEmpty == true && sheet?.message == "Link taken back." && spaceLink.map { !center.holdsToken(for: $0.id) } == true,
                       "paritysharing: Take Back forgets the link and its key (\(sheet?.message ?? "-"))")
            sheet?.close()
            Task { @MainActor in
                var gone = false
                do { _ = try await center.service.snapshot(id: spaceLink?.id ?? "") } catch SharingService.Failure.notFound { gone = true } catch {}
                var page = 0
                if let r = spaceLink {
                    var req = URLRequest(url: r.url)
                    center.service.extraHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                    page = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                }
                self.check(gone && page == 404, "paritysharing: a link taken back 404s (API and page \(page))")
                ShareLinkImport.lastError = nil
                let spaces = self.c.store.orderedSpaces.count
                if let r = spaceLink { self.app?.routeExternal(r.url) }
                self.waitUntil({ ShareLinkImport.lastError != nil }, timeout: 10) {
                    self.check(ShareLinkImport.lastError == SharingService.Failure.notFound.localizedDescription
                               && ShareImportSheet.active[ObjectIdentifier(self.c.window)] == nil && self.c.store.orderedSpaces.count == spaces,
                               "paritysharing: opening a link taken back says so and adds nothing (\(ShareLinkImport.lastError ?? "-"))")
                    if let alert = self.c.window.attachedSheet { self.c.window.endSheet(alert) }
                    done()
                }
            }
        } }

        // Unsafe addresses: refused before sending, and by the service if sent anyway.
        step { [self] done in
            Task { @MainActor in
                let unsafe = ShareSnapshot(.folder(name: "Bad", icon: nil, items: [.tab(ShareTab(url: "javascript:alert(1)"))]))
                var local = false, served = ""
                do { try SharingService.check(unsafe) } catch { local = (error as? ShareLink.Failure) == .unsafeAddress }
                do { _ = try await center.service.publish(unsafe) } catch SharingService.Failure.refused(let why) { served = why } catch {}
                check(local && served.contains("only web addresses"), "paritysharing: a javascript: address is refused before sending and by the service (\(served))")
                done()
            }
        }

        // Fragment links (P17a): still opened, and hostile ones refused whole.
        run { [self] in
            guard let app else { return }
            func packed(_ json: String) -> URL {
                let d = Data(json.utf8)
                var out = Data(count: d.count + 1024)
                let n = out.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in
                    compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count, src.bindMemory(to: UInt8.self).baseAddress!,
                                              src.count, nil, COMPRESSION_ZLIB) } }
                let b = out.prefix(n).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                return URL(string: "https://aircbrowser.com/s#v1.\(b)")!
            }
            if let draft = c.store.shareDraft(ofFolder: folderID), let url = try? ShareLink.url(for: draft.snapshot) {
                app.routeExternal(url)
                let sheet = ShareImportSheet.active[ObjectIdentifier(c.window)]
                check(sheet?.snapshot == draft.snapshot, "paritysharing: a fragment link (made by an earlier Airc) still opens its preview")
                sheet?.close()
            }
            let cases: [(String, URL, String)] = [
                ("damaged", URL(string: "https://aircbrowser.com/s#v1.AAAAAAAA")!, ShareLink.Failure.damaged.localizedDescription),
                ("newer", URL(string: "https://aircbrowser.com/s#v2.AAAA")!, ShareLink.Failure.newerVersion.localizedDescription),
                ("javascript:", packed("{\"kind\":\"folder\",\"name\":\"x\",\"items\":[{\"type\":\"tab\",\"url\":\"javascript:alert(1)\"}]}"),
                 ShareLink.Failure.unsafeAddress.localizedDescription),
                ("data:", packed("{\"kind\":\"folder\",\"name\":\"x\",\"items\":[{\"type\":\"tab\",\"url\":\"data:text/html,hi\"}]}"),
                 ShareLink.Failure.unsafeAddress.localizedDescription),
                ("file:", packed("{\"kind\":\"folder\",\"name\":\"x\",\"items\":[{\"type\":\"tab\",\"url\":\"file:///etc/hosts\"}]}"),
                 ShareLink.Failure.unsafeAddress.localizedDescription),
                ("zip bomb", packed("{\"kind\":\"folder\",\"name\":\"a\",\"items\":[]" + String(repeating: " ", count: 2_000_000) + "}"),
                 ShareLink.Failure.tooLarge.localizedDescription),
            ]
            let spaces = c.store.orderedSpaces.count, items = c.store.state.items.count
            var refused: [String] = []
            for (name, url, message) in cases {
                ShareLinkImport.lastError = nil
                app.routeExternal(url)
                if ShareLinkImport.lastError == message && ShareImportSheet.active[ObjectIdentifier(c.window)] == nil { refused.append(name) }
                if let alert = c.window.attachedSheet { c.window.endSheet(alert) }
            }
            check(refused.count == cases.count && c.store.orderedSpaces.count == spaces && c.store.state.items.count == items,
                  "paritysharing: damaged, newer, javascript:, data:, file: and zip-bomb links are refused whole, nothing added (\(refused))")
        }

        paritySharingGallery(base: base)

        run { [self] in
            if let r = folderLink { Task { @MainActor in try? await center.revoke(r) } }
            if let oldBoard { WindowController.linkPasteboard = oldBoard }
            for s in [sid, otherSid] where c.store.space(s) != nil { try? c.store.deleteSpace(s) }
        }
        wait(1)
    }

    /// B03: submit, approve (the admin page), list, Get, Report; offline, Airc's own remain.
    private func paritySharingGallery(base: URL) {
        let center = SharingCenter.shared
        let name = "Calm Lisbon \(Int(Date().timeIntervalSince1970) % 100000)"
        var submittedID = ""
        step { [self] done in
            Task { @MainActor in
                let file = BoostFile(boost: Boost(domain: "visitlisboa.example", colors: .init(hue: 0.1, tint: 0.2),
                                                  css: "main { line-height: 1.6 !important; }", created: Date(timeIntervalSince1970: 1_800_000_000)),
                                     name: name)
                var f = file
                f.author = "Parity check"
                f.about = "A check's Boost, removed again."
                // The share sheet's Submit to the Gallery where Boosts run (Chromium); the same request otherwise.
                var sent: String?
                if let boosts = BoostCenter.shared, (try? boosts.store.install(f, replacing: true, gallery: false)) != nil,
                   let sheet = BoostShareSheet(domain: f.site, parent: c.window, controller: c, center: boosts) {
                    sheet.name = name
                    sheet.author = "Parity check"
                    sheet.about = "A check's Boost, removed again."
                    sheet.includeScreenshot = false
                    sheet.submitToGallery()
                    for _ in 0..<100 where sheet.submitted == nil && sheet.message == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    sent = sheet.submitted
                    if sent == nil { note("paritysharing: submit said \(sheet.message ?? "nothing")") }
                    sheet.close()
                    boosts.store.remove(domain: f.site)
                } else {
                    sent = try? await center.service.submit(f)
                }
                let refused: String
                do {
                    var bad = f
                    bad.css = "@import \"https://tracker.example/x.css\";"
                    _ = try await center.service.submit(bad)
                    refused = "accepted"
                } catch { refused = error.localizedDescription }
                check(sent != nil && refused.contains("another site"),
                      "paritysharing: Submit to the Gallery queues a Boost (\(sent ?? "-")); one that loads from another site is refused (\(refused))")
                // The owner approves it on the admin page.
                let admin = ProcessInfo.processInfo.environment["AIRC_SHARING_ADMIN"] ?? "local-admin-secret-for-checks-only"
                func adminRequest(_ body: String?) -> URLRequest {
                    var r = URLRequest(url: base.appendingPathComponent("admin/boosts"))
                    r.setValue("Basic " + Data("owner:\(admin)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                    center.service.extraHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                    if let body {
                        r.httpMethod = "POST"
                        r.httpBody = Data(body.utf8)
                        r.setValue("\(base.scheme ?? "http")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
                        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    }
                    return r
                }
                let page = (try? await URLSession.shared.data(for: adminRequest(nil))).map { String(decoding: $0.0, as: UTF8.self) } ?? ""
                let marker = #"name="action" value="approve"><input type="hidden" name="id" value=""#
                if let range = page.range(of: name), let m = page.range(of: marker, range: range.upperBound..<page.endIndex) {
                    let id = String(page[m.upperBound...].prefix(12))
                    if HostedShareLink.isID(id) {
                        submittedID = id
                        _ = try? await URLSession.shared.data(for: adminRequest("action=approve&id=\(submittedID)"))
                    }
                }
                check(!submittedID.isEmpty, "paritysharing: the submission waits in the admin page's queue, and the owner approves it")
                done()
            }
        }
        run { [self] in
            guard let app else { return }
            BoostGalleryWindow.show(app: app)
        }
        step { [self] done in waitUntil({ BoostGalleryWindow.shared?.community.entries.contains { $0.id == submittedID } == true }, timeout: 15) {
            let g = BoostGalleryWindow.shared
            let entry = g?.community.entries.first { $0.id == submittedID }
            self.check(entry?.name == name && entry?.author == "Parity check" && !BoostGallery.entries.isEmpty && entry?.link != nil,
                       "paritysharing: File › Boost Gallery lists the approved Boost beside Airc's own \(BoostGallery.entries.count) (\(g?.community.entries.count ?? 0) from the community)")
            guard let g, let entry else { return done() }
            g.get(entry)
            self.waitUntil({ BoostImportReview.active[ObjectIdentifier(self.c.window)] != nil || g.community.message != nil }, timeout: 10) {
                let review = BoostImportReview.active[ObjectIdentifier(self.c.window)]
                self.check(BoostCenter.shared == nil || review?.file.name == name,
                           "paritysharing: Get fetches the file and opens the usual review (\(review?.file.name ?? (BoostCenter.shared == nil ? "no Boosts on this engine" : g.community.message ?? "none")))")
                review?.cancel()
                // Installed from the gallery, its card offers Review; a later revision of it offers Update.
                if let boosts = BoostCenter.shared, let file = review?.file,
                   (try? boosts.store.install(file, replacing: true, gallery: false)) != nil {
                    let have = BoostGalleryView.installedByID()[entry.fileID ?? ""]
                    var later = entry
                    later.revision = (entry.revision ?? 0) + 1
                    let labels = [entry.action(installed: have), later.action(installed: have)].map(\.rawValue)
                    self.check(entry.revision == file.revision && labels == ["Review", "Update"],
                               "paritysharing: an installed community Boost offers Review, a later revision of it Update (\(labels), revision \(entry.revision.map(String.init) ?? "none"))")
                    boosts.store.remove(domain: file.site)
                }
                g.community.report(entry, .broken)
                self.waitUntil({ g.community.reported.contains(entry.id) }, timeout: 10) {
                    self.check(g.community.reported.contains(entry.id), "paritysharing: Report sends a report about it")
                    done()
                }
            }
        } }
        step { [self] done in
            // Offline: the community part says so; Airc's own are there regardless.
            let offline = CommunityGallery(service: SharingService(base: URL(string: "http://127.0.0.1:9")!))
            waitUntil({ offline.phase != .loading }, timeout: 10) {
                self.check(offline.phase == .unavailable && !BoostGallery.entries.isEmpty,
                           "paritysharing: without the service the gallery says so and keeps Airc's own \(BoostGallery.entries.count) Boosts")
                BoostGalleryWindow.shared?.window.close()
                done()
            }
        }
        // The check's Boost leaves the gallery again.
        step { [self] done in
            Task { @MainActor in
                if !submittedID.isEmpty {
                    let admin = ProcessInfo.processInfo.environment["AIRC_SHARING_ADMIN"] ?? "local-admin-secret-for-checks-only"
                    var r = URLRequest(url: base.appendingPathComponent("admin/boosts"))
                    r.httpMethod = "POST"
                    r.httpBody = Data("action=remove&id=\(submittedID)".utf8)
                    r.setValue("Basic " + Data("owner:\(admin)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                    r.setValue("\(base.scheme ?? "http")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
                    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    center.service.extraHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                    _ = try? await URLSession.shared.data(for: r)
                }
                done()
            }
        }
    }
}
#endif

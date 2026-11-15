// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityh03` (both engines): H03's Share in a private window (Sharing/PrivateShare.swift). File › Share there
/// hands the system's share picker the page's link alone, without trackers (the picker itself needs a person, so the
/// check takes the share where it would be shown, and sends it through a test service as choosing one would). Airc
/// keeps nothing of it: none of Airc's files in the data folder changes, no file that changed anywhere in it (the
/// engine's own profile folder too, which Chromium keeps writing on its own schedule) holds the link, and no history
/// entry or recent item is added. Loopback only.
extension SnapshotRunner {
    func parityH03Scenario() {
        var server: LocalPageServer?, port: UInt16 = 0
        var window: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            server = LocalPageServer(pages: ["/p": "<title>Private page</title><p>Nothing to keep</p>"])
            server?.start { p in
                port = p ?? 0
                PrivateBrowsing.shared.open(app: app) { w in window = w; done() }
            }
            if server == nil { done() }
        }
        step { [self] done in
            guard let w = window else { return done() }
            w.openPage(URL(string: "http://127.0.0.1:\(port)/p?utm_source=newsletter&id=3"))
            waitUntil({ w.shownPage.map { $0.title == "Private page" && !$0.isLoading } ?? false }, timeout: 8) { done() }
        }
        wait(1)
        run { [self] in
            guard let w = window, let app else { return check(false, "parityh03: a private window with a page") }
            // Everything in the data folder (path, size, modification date), history and recent items, before.
            let engineFolder = AppPaths.chromium.standardizedFileURL.path + "/"
            func files() -> [String: String] {
                let root = AppPaths.dataDirectory
                var out: [String: String] = [:]
                let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
                for case let u as URL in e {
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    out[u.path] = "\(v.fileSize ?? 0) \(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                }
                return out
            }
            let history = { app.store.state.profiles.keys.reduce(0) { $0 + app.history.entries(ofProfile: $1).count } }
            let before = files(), historyBefore = history(), recentsBefore = NSDocumentController.shared.recentDocumentURLs

            var taken: SelectionShare?
            PrivateWindowController.shareProbe = { taken = $0 }
            let handled = w.perform(menuTitle: "Share")
            PrivateWindowController.shareProbe = nil
            var sent: [Any] = []
            let service = NSSharingService(title: "Airc Check Share", image: NSImage(size: NSSize(width: 16, height: 16)), alternateImage: nil) {}
            SelectionShare.testService = service
            SelectionShare.testShared = { title, items in if title == "Airc Check Share" { sent = items } }
            taken?.perform(service)
            SelectionShare.testService = nil
            SelectionShare.testShared = nil
            let urls = (sent as? [URL])?.map(\.absoluteString) ?? sent.map { "\($0)" }
            check(handled && taken != nil && urls == ["http://127.0.0.1:\(port)/p?id=3"] && sent.count == 1,
                  "parityh03: a private window's Share hands the picker the page's link alone, without trackers (\(urls))")

            // A moment for anything that would be written.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = files()
                let changed = Set(before.keys).symmetricDifference(after.keys).union(before.keys.filter { after[$0] != nil && after[$0] != before[$0] })
                let airc = changed.filter { !URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(engineFolder) }
                self.check(airc.isEmpty, "parityh03: none of Airc's files in the data folder changes (\(airc.map { ($0 as NSString).lastPathComponent }.sorted()))")
                let link = Data("127.0.0.1:\(port)/p".utf8)
                let holding = changed.filter { (try? Data(contentsOf: URL(fileURLWithPath: $0)))?.range(of: link) != nil }
                self.check(holding.isEmpty, "parityh03: no file that changed holds the shared link (\(changed.count) changed, the engine's own profile included; \(holding.map { ($0 as NSString).lastPathComponent }.sorted()))")
                self.check(history() == historyBefore && NSDocumentController.shared.recentDocumentURLs == recentsBefore,
                           "parityh03: no history entry and no recent item")
            }
        }
        wait(1.5)
        run {
            window?.closeWindow()
            server?.stop()
        }
    }
}
#endif

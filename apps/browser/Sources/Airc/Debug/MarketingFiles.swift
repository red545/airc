// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of P04 (part "views"):
///   - sidebar-files: a "Lisbon trip" folder dropped on the Travel Space's sidebar, in the pinned section with its files
///     as tabs and its Tickets folder inside; its itinerary (a local web page) open, and the toast that says what came in.
/// The folder is a synthetic one in /tmp (no home folder in any address), made for the shot and deleted after it.
extension SnapshotRunner {
    static let mkFilesRoot = URL(fileURLWithPath: "/tmp/Lisbon trip")

    func mkFilesShots(_ d: MarketingDemo) {
        let root = Self.mkFilesRoot
        let fm = FileManager.default
        var itinerary: String?
        run {
            func write(_ path: String, _ text: String) {
                let u = root.appendingPathComponent(path)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: u, atomically: true, encoding: .utf8)
            }
            try? fm.removeItem(at: root)
            write("Itinerary.html", Self.mkItineraryPage)
            write("Packing list.txt", "Packing list\n\nPassport\nSunscreen\nLight jacket for the evenings\nComfortable shoes (hills!)\nCamera\n")
            write("Restaurants.html", "<!doctype html><title>Restaurants</title><h1>Where to eat</h1><p>Taberna da Rua das Flores</p>")
            write("Tickets/Tram 28.html", "<!doctype html><title>Tram 28</title><h1>Tram 28</h1><p>Day pass</p>")
            write("Tickets/Castelo de São Jorge.html", "<!doctype html><title>Castelo de São Jorge</title><h1>Castle</h1>")
        }
        mkShow(d, "travel", nil)
        mkSettleShown(timeout: 8, extra: 0.4)
        step { [self] done in
            guard let sid = d.space["travel"] else { note("marketing: MISSING sidebar-files: no Travel Space"); return done() }
            SidebarFileImport.confirmOverride = { _ in true }
            let op = c.importIntoSidebar([.file(root)], destination: SidebarFileDestination(spaceID: sid))
            waitUntil({ op?.isFinished ?? true }, timeout: 8) {
                SidebarFileImport.confirmOverride = nil
                // The itinerary, as a click on its row opens it.
                let folder = self.c.store.pinnedRoots(ofSpace: sid).last(where: { $0.title == "Lisbon trip" })
                if let item = folder.flatMap({ f in self.c.store.children(of: .pinned(spaceID: sid), parent: f.id).first { $0.pageTitle == "Itinerary.html" } }),
                   let tab = try? self.c.store.openItem(item.id, inSpace: sid) {
                    itinerary = tab.id
                    self.c.show(tab.id, focus: false)
                } else {
                    self.note("marketing: MISSING sidebar-files: the folder didn't come in")
                }
                done()
            }
        }
        mkSettle({ [self] in [itinerary.flatMap { c.engineTab(for: $0) }] }, timeout: 8, extra: 0.6)
        run { [self] in c.showToast("Added 5 tabs and 2 folders to Travel") }
        wait(0.3)
        mkWindowShot("sidebar-files")
        run { [self] in
            // Back as it was for the next shots: one ⌘Z takes the drop back.
            c.undo()
            try? fm.removeItem(at: root)
        }
    }

    static let mkItineraryPage = """
        <!doctype html><html><head><meta charset=utf-8><title>Lisbon — three days</title>
        <style>
        body{margin:0;font:16px/1.55 -apple-system,system-ui,sans-serif;color:#1f2a33;background:#f7f4ee}
        header{padding:42px 56px 26px;background:linear-gradient(135deg,#f3c66b,#e98a5a);color:#2b1d12}
        header small{letter-spacing:.12em;font-weight:600;font-size:12px;opacity:.75}
        h1{font:700 40px/1.1 ui-serif,Georgia,serif;margin:8px 0 6px}
        main{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;padding:28px 56px}
        section{background:#fff;border-radius:14px;padding:18px 20px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
        h2{font-size:15px;margin:0 0 8px;color:#b4552b}
        li{margin:4px 0}
        </style></head><body>
        <header><small>ITINERARY</small><h1>Lisbon, three days</h1><div>Trams, tiles and pastéis de nata</div></header>
        <main>
        <section><h2>Day 1 · Alfama</h2><ul><li>Tram 28 from Martim Moniz</li><li>Castelo de São Jorge</li><li>Fado in the evening</li></ul></section>
        <section><h2>Day 2 · Belém</h2><ul><li>Jerónimos Monastery</li><li>Pastéis de Belém</li><li>Sunset at the tower</li></ul></section>
        <section><h2>Day 3 · Chiado</h2><ul><li>Livraria Bertrand</li><li>Miradouro de Santa Catarina</li><li>Time Out Market</li></ul></section>
        </main></body></html>
        """
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// What lands on an Easel: blocks from another Easel, pictures (files, a page's image, a screenshot), links (a page's
/// link, a sidebar row) as link cards, and text as a text block. Capture's "Add to Easel" too.
enum EaselDrops {
    /// A drag's or paste's pasteboard dropped at `p` on the plane. True when something landed.
    static func drop(_ pb: NSPasteboard, on editor: EaselEditor, at p: EaselPoint) -> Bool {
        if pb.data(forType: EaselEditor.blocksType) != nil {
            let saved = EaselEditor.pasteboard
            EaselEditor.pasteboard = { pb }
            editor.paste(at: p)
            EaselEditor.pasteboard = saved
            return true
        }
        let images = EaselCenter.shared.readPictures(pb, into: editor.easelID)
        if !images.isEmpty {
            var q = p
            var made: Set<String> = []
            for i in images {
                made.insert(editor.addImage(i, at: q))
                q = q.offsetBy(dx: 30, dy: 30)
            }
            editor.selection = made
            editor.focus()
            return true
        }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if !urls.isEmpty {
            // A page's link drag names its title in the URL-name type.
            let title = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            var q = p
            var made: Set<String> = []
            for u in urls {
                made.insert(editor.addLink(u, title: urls.count == 1 ? title : nil, at: q))
                q = q.offsetBy(dx: 0, dy: EaselLink.defaultSize.height + 16)
            }
            editor.selection = made
            editor.focus()
            return true
        }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if let u = EaselEditor.webURL(s) { editor.addLink(u, at: p) } else {
                editor.addText(EaselText(plain: s, font: EaselEditor.lastFont, size: EaselEditor.lastTextSize), at: EaselPoint(p.x - 160, p.y - 20), width: 320, name: "Drop Text")
            }
            editor.focus()
            return true
        }
        return false
    }
}

extension WindowController {
    /// Sidebar rows let go over an Easel on screen (Sidebar/SpacePage.swift's row drag): each page becomes a link card
    /// where it was dropped, the rows stay where they were. True when they landed.
    func dropRowsOnEasel(_ sources: [DragSource], windowPoint: NSPoint) -> Bool {
        guard let e = shownEasel, let canvas = e.view?.canvas else { return false }
        let local = canvas.convert(windowPoint, from: nil)
        guard canvas.bounds.contains(local) else { return false }
        var links: [(URL, String?)] = []
        func add(url: String?, title: String?) {
            guard let url, !LocalDocumentURL.isLocal(url), let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
            links.append((u, title))
        }
        for s in sources {
            switch s {
            case .tab(let id): if let t = store.tab(id) { add(url: t.url, title: t.title) }
            case .item(let id):
                guard let i = store.item(id) else { continue }
                if i.kind == .folder {
                    for c in store.children(of: i.container, parent: i.id) { add(url: c.savedURL, title: c.displayTitle) }
                } else {
                    add(url: store.liveTab(forItem: id)?.url ?? i.savedURL, title: i.displayTitle)
                }
            case .split(let id): for t in store.split(id).map({ store.members(of: $0) }) ?? [] { add(url: t.url, title: t.title) }
            }
        }
        guard !links.isEmpty else { return false }
        var q = canvas.plane(local)
        var made: Set<String> = []
        for (u, title) in links.prefix(50) {
            made.insert(e.addLink(u, title: title, at: q))
            q = q.offsetBy(dx: 0, dy: EaselLink.defaultSize.height + 16)
        }
        e.selection = made
        e.focus()
        return true
    }
}

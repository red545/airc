// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// P04 (L07): a Space, or every Space, as a file another app can read: Markdown (nested lists of `[title](url)`), or HTML
/// in the bookmarks format every browser imports (Netscape's `<DL>`/`<DT>`). The names, the order, the folders and the
/// addresses are the sidebar's, with nothing private:
///   - a link's user name and password (`https://user:pass@host`) are taken out;
///   - `data:`, `blob:` and `javascript:` links are left out (they can carry a page's data or a script);
///   - a note is listed by its title, without its text;
///   - private windows' tabs aren't in the store at all, and blank windows' Spaces (WIN-7) aren't exported.
/// Pinned tabs export their saved address (the one the row stands for), Today tabs their current one.
public enum SidebarExportFormat: String, CaseIterable, Sendable {
    case markdown, html
    public var fileExtension: String { self == .markdown ? "md" : "html" }
}

/// One exported row, as the sidebar shows it.
public struct SidebarExportNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case link(url: String), folder([SidebarExportNode]), note }
    public var title: String
    public var kind: Kind
    public init(title: String, kind: Kind) {
        self.title = title
        self.kind = kind
    }
}

/// A Space's export: its Pinned and Today rows.
public struct SidebarExportSpace: Equatable, Sendable {
    public var name: String
    public var icon: String?
    public var pinned: [SidebarExportNode]
    public var today: [SidebarExportNode]
}

/// A profile's Favorites (exported once, with every Space).
public struct SidebarExportFavorites: Equatable, Sendable {
    public var profile: String
    public var rows: [SidebarExportNode]
}

public enum SidebarExport {
    /// An address as it may leave the app: no user name or password; nil for data:, blob: and javascript: links.
    public static func exportedURL(_ url: String) -> String? {
        let scheme = url.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        guard !["data", "blob", "javascript"].contains(scheme) else { return nil }
        guard var c = URLComponents(string: url), c.user != nil || c.password != nil else { return url }
        c.user = nil
        c.password = nil
        return c.string ?? url
    }

    public static func markdown(spaces: [SidebarExportSpace], favorites: [SidebarExportFavorites] = []) -> String {
        var out: [String] = []
        func rows(_ nodes: [SidebarExportNode], depth: Int) {
            for n in nodes {
                let indent = String(repeating: "  ", count: depth)
                switch n.kind {
                case .link(let u): out.append(indent + "- " + URLRules.markdownLink(title: n.title, url: u))
                case .note: out.append(indent + "- " + URLRules.markdownListText(n.title) + " (note)")
                case .folder(let kids):
                    out.append(indent + "- " + URLRules.markdownListText(n.title))
                    rows(kids, depth: depth + 1)
                }
            }
        }
        for f in favorites where !f.rows.isEmpty {
            out.append("# Favorites (\(heading(f.profile)))")
            out.append("")
            rows(f.rows, depth: 0)
            out.append("")
        }
        for s in spaces {
            out.append("# " + heading((s.icon.map { $0 + " " } ?? "") + s.name))
            for (name, nodes) in [("Pinned", s.pinned), ("Today", s.today)] where !nodes.isEmpty {
                out.append("")
                out.append("## " + name)
                out.append("")
                rows(nodes, depth: 0)
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The bookmarks file browsers import: each Space a folder with Pinned and Today folders, Favorites a folder per
    /// profile.
    public static func html(spaces: [SidebarExportSpace], favorites: [SidebarExportFavorites] = [], title: String) -> String {
        var out = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
                   "<!-- Exported from Airc. -->",
                   "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
                   "<TITLE>\(escape(title))</TITLE>",
                   "<H1>\(escape(title))</H1>",
                   "<DL><p>"]
        func folder(_ name: String, _ nodes: [SidebarExportNode], depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            out.append(pad + "<DT><H3>\(escape(name))</H3>")
            out.append(pad + "<DL><p>")
            rows(nodes, depth: depth + 1)
            out.append(pad + "</DL><p>")
        }
        func rows(_ nodes: [SidebarExportNode], depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            for n in nodes {
                switch n.kind {
                case .link(let u): out.append(pad + "<DT><A HREF=\"\(escape(u))\">\(escape(n.title.isEmpty ? u : n.title))</A>")
                case .folder(let kids): folder(n.title, kids, depth: depth)
                case .note: out.append(pad + "<DT>\(escape(n.title)) (note)")
                }
            }
        }
        for f in favorites where !f.rows.isEmpty { folder("Favorites (\(f.profile))", f.rows, depth: 1) }
        for s in spaces {
            let pad = String(repeating: "    ", count: 1)
            out.append(pad + "<DT><H3>\(escape((s.icon.map { $0 + " " } ?? "") + s.name))</H3>")
            out.append(pad + "<DL><p>")
            if !s.pinned.isEmpty { folder("Pinned", s.pinned, depth: 2) }
            if !s.today.isEmpty { folder("Today", s.today, depth: 2) }
            out.append(pad + "</DL><p>")
        }
        out.append("</DL><p>")
        return out.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A heading's text on one line, its leading `#` escaped.
    static func heading(_ s: String) -> String {
        let one = s.components(separatedBy: .newlines).joined(separator: " ")
        return one.hasPrefix("#") ? "\\" + one : one
    }
}

extension SpacesStore {
    /// A Space as the export writes it (nil for a blank window's Space or one that's gone).
    public func exportSpace(_ id: String) -> SidebarExportSpace? {
        guard let s = space(id), !s.isBlankWindow else { return nil }
        let icon: String? = if case .emoji(let e)? = s.icon { e } else { nil }
        return SidebarExportSpace(name: s.name, icon: icon, pinned: exportRows(.pinned(spaceID: id), parent: nil),
                                  today: todayRows(ofSpace: id).flatMap(exportRow(today:)))
    }

    /// Every listed Space, in Space bar order.
    public func exportAllSpaces() -> [SidebarExportSpace] { orderedSpaces.compactMap { exportSpace($0.id) } }

    /// Each profile's Favorites that has any, in profile order.
    public func exportFavorites() -> [SidebarExportFavorites] {
        orderedProfiles.map { SidebarExportFavorites(profile: $0.name, rows: exportRows(.favorites(profileID: $0.id), parent: nil)) }
            .filter { !$0.rows.isEmpty }
    }

    private func exportRows(_ container: ItemContainer, parent: String?) -> [SidebarExportNode] {
        children(of: container, parent: parent).flatMap { i -> [SidebarExportNode] in
            switch i.kind {
            case .folder: return [SidebarExportNode(title: i.displayTitle, kind: .folder(exportRows(container, parent: i.id)))]
            case .split: return exportRows(container, parent: i.id)
            case .tab: return exportNode(title: i.displayTitle, url: i.savedURL).map { [$0] } ?? []
            }
        }
    }

    private func exportRow(today e: SidebarEntry) -> [SidebarExportNode] {
        switch e {
        case .split(_, let tabs): return tabs.compactMap { exportNode(title: $0.displayTitle, url: $0.url) }
        default: return e.liveTab.flatMap { exportNode(title: $0.displayTitle, url: $0.url) }.map { [$0] } ?? []
        }
    }

    private func exportNode(title: String, url: String?) -> SidebarExportNode? {
        guard let url else { return nil }
        if NoteURL.isNote(url) { return SidebarExportNode(title: title, kind: .note) }
        return SidebarExport.exportedURL(url).map { SidebarExportNode(title: title, kind: .link(url: $0)) }
    }
}

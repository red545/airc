// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A bookmarks HTML file ("NETSCAPE-Bookmark-file-1"): what Safari's File → Export → Bookmarks… writes, and Chrome's,
/// Edge's and Firefox's exports too. Folders are `<DT><H3>name</H3>` followed by a `<DL>` of their entries, bookmarks
/// `<DT><A HREF="…">name</A>`. Read with a byte scanner, so a file full of inline icons (`ICON="data:…"`) stays fast.
///
/// The bookmarks bar is the folder marked `PERSONAL_TOOLBAR_FOLDER` (Chrome, Firefox) or Safari's top-level
/// "Favorites"; its entries become pinned tabs and folders. Every other top-level folder stays one pinned folder, and
/// loose top-level bookmarks go into one more ("Other bookmarks"; "Bookmarks Menu" for Firefox, which exports its menu
/// that way). The file has no bookmark IDs, so each entry's ID is a hash of its folder path, address and name: the
/// same export imported again updates in place.
public enum BookmarksFile {
    final class Folder {
        var title: String
        var attributes: [String: String]
        var entries: [Entry] = []
        init(_ title: String, _ attributes: [String: String]) { self.title = title; self.attributes = attributes }
    }

    enum Entry {
        case link(title: String, href: String, attributes: [String: String])
        case folder(Folder)
    }

    static let favoritesNames: Set<String> = ["favorites", "favourites", "favoriten", "favoris", "preferiti", "favoritos", "bookmarks bar", "bookmarksbar"]

    /// The file's tree, and which browser wrote it when that shows (Firefox and Safari leave marks; Chromium browsers
    /// all write the same file).
    static func parse(_ data: Data) throws -> (root: Folder, kind: BrowserKind?) {
        let bytes = [UInt8](data)
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self).lowercased()
        guard head.contains("netscape-bookmark-file") || head.contains("<dl") else { throw ImportError.invalidBookmarks }
        let root = Folder("", [:])
        var stack = [root]
        var pending: Folder?
        var opened = false
        var firefox = false
        var i = 0
        let n = bytes.count
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }
        while i < n {
            guard bytes[i] == 0x3C else { i += 1; continue }   // "<"
            var j = i + 1
            var closing = false
            if j < n, bytes[j] == 0x2F { closing = true; j += 1 }   // "/"
            var name: [UInt8] = []
            while j < n, name.count < 8 {
                let c = lower(bytes[j])
                guard (c >= 97 && c <= 122) || (c >= 48 && c <= 57) else { break }
                name.append(c)
                j += 1
            }
            // The tag's attributes, up to its ">" (quoted values may hold one).
            var attrs: [String: String] = [:]
            var quote: UInt8 = 0
            let attrStart = j
            while j < n {
                let c = bytes[j]
                if quote != 0 { if c == quote { quote = 0 } } else if c == 0x22 || c == 0x27 { quote = c } else if c == 0x3E { break }
                j += 1
            }
            let tag = String(decoding: name, as: UTF8.self)
            if !closing, tag == "a" || tag == "h3" || tag == "h1" { attrs = attributes(bytes[attrStart..<min(j, n)]) }
            i = j + 1
            // Text up to the next tag: the bookmark's or folder's name.
            func text() -> String {
                var k = i
                while k < n, bytes[k] != 0x3C { k += 1 }
                let s = decodeEntities(String(decoding: bytes[i..<k], as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
                i = k
                return s
            }
            switch (closing, tag) {
            case (false, "h1"):
                if text().lowercased() == "bookmarks menu" { firefox = true }
            case (false, "h3"):
                let f = Folder(text(), attrs)
                if attrs["unfiled_bookmarks_folder"] != nil { firefox = true }
                stack[stack.count - 1].entries.append(.folder(f))
                pending = f
            case (false, "a"):
                let title = text()
                stack[stack.count - 1].entries.append(.link(title: title, href: attrs["href"] ?? "", attributes: attrs))
                pending = nil
            case (false, "dl"):
                if let f = pending {
                    if stack.count <= BookmarkBuilder.maxDepth { stack.append(f) } else { stack.append(stack[stack.count - 1]) }
                    pending = nil
                } else if !opened {
                    opened = true
                } else {
                    stack.append(stack[stack.count - 1])   // a stray list: its entries stay where they are
                }
            case (true, "dl"):
                if stack.count > 1 { stack.removeLast() }
                pending = nil
            default:
                break
            }
        }
        var kind: BrowserKind? = firefox ? .firefox : nil
        if kind == nil {
            for case .folder(let f) in root.entries where f.attributes["id"] == "com.apple.ReadingList"
                || (f.attributes["personal_toolbar_folder"] == nil && favoritesNames.contains(f.title.lowercased())) {
                kind = .safari
            }
        }
        return (root, kind)
    }

    /// `HREF="…" ADD_DATE=… PERSONAL_TOOLBAR_FOLDER="true"` with lowercased names.
    static func attributes(_ s: ArraySlice<UInt8>) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        let end = s.endIndex
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        while i < end {
            while i < end, isSpace(s[i]) { i += 1 }
            var name: [UInt8] = []
            while i < end, !isSpace(s[i]), s[i] != 0x3D, s[i] != 0x3E { name.append(s[i] >= 65 && s[i] <= 90 ? s[i] + 32 : s[i]); i += 1 }
            while i < end, isSpace(s[i]) { i += 1 }
            var value = ""
            if i < end, s[i] == 0x3D {
                i += 1
                while i < end, isSpace(s[i]) { i += 1 }
                if i < end, s[i] == 0x22 || s[i] == 0x27 {
                    let q = s[i]
                    i += 1
                    let start = i
                    while i < end, s[i] != q { i += 1 }
                    // Inline icons can be megabytes; nobody needs them.
                    if !name.elementsEqual("icon".utf8) { value = String(decoding: s[start..<i], as: UTF8.self) }
                    i += 1
                } else {
                    let start = i
                    while i < end, !isSpace(s[i]) { i += 1 }
                    value = String(decoding: s[start..<i], as: UTF8.self)
                }
            }
            if !name.isEmpty { out[String(decoding: name, as: UTF8.self)] = decodeEntities(value) }
            if name.isEmpty && value.isEmpty { i += 1 }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else { out += "&"; rest = after; continue }
            let entity = after[..<semi]
            var decoded: String?
            switch entity.lowercased() {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            case "nbsp": decoded = "\u{a0}"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
            }
            if let decoded { out += decoded; rest = after[after.index(after: semi)...] } else { out += "&"; rest = after }
        }
        return out + rest
    }

    /// The bar and the pinned folders, with stable path-hash IDs.
    static func tree(_ root: Folder, kind: BrowserKind?, _ b: inout BookmarkBuilder) -> (bar: [ImportedItem], folders: [ImportedFolder]) {
        var occurrences: [String: Int] = [:]
        func key(_ base: String) -> String {
            let n = occurrences[base, default: 0]
            occurrences[base] = n + 1
            return n == 0 ? base : base + "#\(n)"
        }
        func items(_ entries: [Entry], path: String, depth: Int) -> [ImportedItem] {
            guard !b.deep(depth) else { b.warn(.depthLimit, "Stopped at a folder nested more than 64 levels deep."); return [] }
            var out: [ImportedItem] = []
            for e in entries {
                switch e {
                case .link(let title, let href, let attrs):
                    let k = key(path + "\u{1f}" + href + "\u{1f}" + title)
                    if let t = b.tab(id: attrs["id"].flatMap(nonempty) ?? hash(k), url: href, name: title) { out.append(t) }
                case .folder(let f):
                    let k = key(path + "/" + f.title)
                    out.append(.folder(b.folder(id: f.attributes["id"].flatMap(nonempty) ?? hash(k), title: f.title,
                                                children: items(f.entries, path: k, depth: depth + 1))))
                }
            }
            return out
        }
        let top = root.entries
        let barIndex = top.firstIndex { if case .folder(let f) = $0 { f.attributes["personal_toolbar_folder"] == "true" } else { false } }
            ?? top.firstIndex { if case .folder(let f) = $0 { favoritesNames.contains(f.title.lowercased()) } else { false } }
        var bar: [ImportedItem] = []
        var folders: [ImportedFolder] = []
        var loose: [Entry] = []
        for (index, e) in top.enumerated() {
            switch e {
            case .folder(let f) where index == barIndex:
                bar = items(f.entries, path: key("/" + f.title), depth: 1)
            case .folder(let f):
                let k = key("/" + f.title)
                let children = items(f.entries, path: k, depth: 1)
                folders.append(b.folder(id: f.attributes["id"].flatMap(nonempty) ?? hash(k), title: f.title, children: children))
            case .link:
                loose.append(e)
            }
        }
        if !loose.isEmpty {
            let children = items(loose, path: key("/loose"), depth: 1)
            if !children.isEmpty {
                folders.insert(b.folder(id: "root:loose", title: kind == .firefox ? "Bookmarks Menu" : "Other bookmarks", children: children), at: 0)
            }
        }
        return (bar, folders)
    }

    /// FNV-1a 64, as hex: short and stable.
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

extension BrowserImporter {
    /// Reads a bookmarks HTML file the user chose (Safari's export, or any browser's). `kind` names the Space when the
    /// user picked the file for a browser (Safari); otherwise the file says, or the Space is "Bookmarks". One profile
    /// ("file") and one Space, keyed on the browser, so the same export imported again updates in place.
    public static func readBookmarksFile(_ url: URL, kind hint: BrowserKind? = nil) async throws -> BrowserImport {
        try await Task.detached {
            let data = try BrowserImporter.readLimited(url)
            let (root, detected) = try BookmarksFile.parse(data)
            let kind = hint ?? detected
            let install = (kind?.rawValue ?? "bookmarks") + "-file"
            let profile = "file"
            var b = BookmarkBuilder(prefix: BrowserImport.Keys.item(install, profile), maxBookmarks: BrowserImporter.maxBookmarks)
            let (bar, folders) = BookmarksFile.tree(root, kind: kind, &b)
            guard b.bookmarks > 0 || b.folders > 0 else { throw ImportError.invalidBookmarks }
            let name = kind?.name ?? "Bookmarks"
            let key = BrowserImport.Keys.profile(install, profile)
            let color = (kind ?? .safari).color
            let plan = ImportPlan(
                profiles: [ImportedProfile(id: key, directory: profile, name: name, avatar: nil, color: nil, isAvailable: true)],
                spaces: [ImportedSpace(id: BrowserImport.Keys.space(install, profile), name: name, emoji: "•", icon: nil,
                                       theme: ImportedTheme(color: color, colors: [color], raw: nil), profileID: key,
                                       pinned: bar + folders.map { .folder($0) }, today: [])],
                favorites: [:], warnings: b.warnings)
            let summary = BrowserProfileSummary(sourceKey: key, profileID: profile, name: name, color: nil, isDefault: true,
                                                bookmarks: b.bookmarks, folders: b.folders, history: 0)
            return BrowserImport(kind: kind, fromFile: true, installID: install, plan: plan, history: [key: []], profiles: [summary])
        }.value
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

typealias Obj = [String: Any]
func obj(_ v: Any?) -> Obj { v as? Obj ?? [:] }
func pairs(_ v: Any?) -> [(Any, Any)] {
    guard let list = v as? [Any] else { return [] }
    var result: [(Any, Any)] = []; var i = 0
    while i < list.count {
        let k = list[i]; let o = obj(k)
        if (k is String || (o.count == 1 && o["id"] == nil)), i + 1 < list.count {
            result.append((k, list[i + 1])); i += 2
        } else { if let id = o["id"] as? String { result.append((id, k)) }; i += 1 }
    }
    return result
}
func label(_ v: Any) -> String? { v as? String ?? obj(v).keys.sorted().first }
func profileID(_ v: Any?) -> String {
    let o = obj(v)
    if o["default"] != nil { return "default" }
    let c = obj(o["custom"]); let inner = c["_0"] == nil ? c : obj(c["_0"])
    return nonempty(inner["directoryBasename"]) ?? nonempty(v) ?? "default"
}
func nonempty(_ v: Any?) -> String? {
    guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
func jsonValue(_ v: Any?) -> JSONValue? {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: d)
}
func colors(_ v: Any?, depth: Int = 0) -> [String] {
    guard depth < 16 else { return [] }
    let o = obj(v)
    if let r = o["red"] as? Double, let g = o["green"] as? Double, let b = o["blue"] as? Double {
        let scale = max(r, g, b) <= 1 ? 255.0 : 1.0
        return [String(format: "#%02x%02x%02x", Int(min(255, max(0, r * scale)).rounded()), Int(min(255, max(0, g * scale)).rounded()), Int(min(255, max(0, b * scale)).rounded()))]
    }
    return (v as? [Any] ?? o.keys.sorted().compactMap { o[$0] }).flatMap { colors($0, depth: depth + 1) }
}
private struct Index {
    var items: [String: Obj] = [:]
    var parents: [String: [String]] = [:]
    init(_ list: Any?) {
        for (k, v) in pairs(list) {
            let o = obj(v)
            guard let id = k as? String ?? o["id"] as? String, !o.isEmpty else { continue }
            items[id] = o
            if let parent = o["parentID"] as? String { parents[parent, default: []].append(id) }
        }
    }
    func children(_ id: String) -> [String] {
        let listed = items[id]?["childrenIds"] as? [String] ?? []
        return listed.isEmpty ? parents[id] ?? [] : listed
    }
}

public enum ArcSidebarParser {
    public static func parse(_ data: Data, includeToday: Bool = true) throws -> ImportPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? Obj,
              let containers = obj(root["sidebar"])["containers"] as? [Any] else { throw ImportError.invalidSidebar }
        var main: Obj?
        for i in containers.indices where i + 1 < containers.count {
            if label(containers[i]) == "global", containers[i + 1] is Obj { main = obj(containers[i + 1]); break }
        }
        if main == nil {
            for i in containers.indices where obj(containers[i])["items"] is [Any] {
                if i == 0 || label(containers[i - 1]) != "littleBrowser" { main = obj(containers[i]); break }
            }
        }
        guard let main else { throw ImportError.invalidSidebar }
        var warnings: [ImportWarning] = []
        func warn(_ code: ImportWarning.Code, _ message: String) { warnings.append(.init(code: code, message: message)) }
        if let version = root["version"] as? Int, version > 1 { warn(.newerVersion, "A newer sidebar version was read using compatible fields.") }
        let index = Index(main["items"])
        var seen = Set<String>()
        /// `keepSplits`: pinned tabs and Favorites keep Arc's split views as splits (SV-2); Today and a split inside a
        /// split flatten them.
        func children(_ index: Index, _ parent: String, _ depth: Int = 0, keepSplits: Bool = true) -> [ImportedItem] {
            if depth > 64 { warn(.depthLimit, "Stopped at a folder nested more than 64 levels deep."); return [] }
            var out: [ImportedItem] = []
            for id in index.children(parent) {
                guard seen.insert(id).inserted else { warn(.cycle, "Skipped a repeated or cyclic item reference."); continue }
                guard let item = index.items[id] else { warn(.missingItem, "A referenced sidebar item is missing."); continue }
                let d = obj(item["data"])
                if let tab = d["tab"] as? Obj {
                    guard let url = nonempty(tab["savedURL"]) else { warn(.invalidTab, "Skipped a tab without a URL."); continue }
                    let page = nonempty(tab["savedTitle"]), title = nonempty(item["title"])
                    out.append(.tab(.init(id: id, url: url, title: title == page ? nil : title, pageTitle: page, lastActiveAt: tab["timeLastActiveAt"] as? Double)))
                } else if d["list"] != nil {
                    if item["automaticLiveFolderData"] != nil { warn(.unsupportedItem, "Imported a live folder as a regular folder.") }
                    out.append(.folder(.init(id: id, title: nonempty(item["title"]) ?? "Folder", children: children(index, id, depth + 1, keepSplits: keepSplits))))
                } else if d["splitView"] != nil {
                    let tabs = children(index, id, depth + 1, keepSplits: false).flatMap(\.tabs)
                    guard keepSplits, tabs.count >= 2 else {
                        warn(.splitView, "Flattened a split view into individual tabs.")
                        out += tabs.map { .tab($0) }
                        continue
                    }
                    // SidebarSplitViewData { itemWidthFactors, layoutOrientation, focusItemID } (older files: "layout").
                    let sv = obj(d["splitView"])
                    let orientation = (sv["layoutOrientation"] ?? sv["layout"] ?? sv["orientation"]).flatMap(label) ?? ""
                    var factors: [String: Double] = [:]
                    if let dict = sv["itemWidthFactors"] as? Obj {
                        for (k, v) in dict { if let n = v as? Double { factors[k] = n } }
                    } else {
                        for (k, v) in pairs(sv["itemWidthFactors"]) { if let k = label(k), let n = v as? Double { factors[k] = n } }
                    }
                    let kept = Array(tabs.prefix(4))
                    out.append(.split(.init(id: id, title: nonempty(item["title"]), axis: orientation.lowercased().contains("vertical") ? "vertical" : "horizontal",
                                            shares: kept.map { factors[$0.id] ?? 0 }, focusedID: sv["focusItemID"] as? String, tabs: kept)))
                    // Arc's limit is four panes; anything past it stays as tabs.
                    out += tabs.dropFirst(4).map { .tab($0) }
                } else {
                    if d["easel"] != nil { warn(.easel, "Skipped an Easel (Arc-only)."); continue }
                    else { warn(.unsupportedItem, "Flattened or skipped an unsupported sidebar item.") }
                    out += children(index, id, depth + 1, keepSplits: keepSplits)
                }
            }
            return out
        }
        let icons = ["briefcase":"💼","house":"🏠","home":"🏠","star":"⭐️","heart":"❤️","book":"📚","bolt":"⚡️","flame":"🔥","leaf":"🌿","globe":"🌍","gamecontroller":"🎮","music":"🎵","cart":"🛒","airplane":"✈️","graduationcap":"🎓","paintbrush":"🎨","hammer":"🔨","person":"👤","sparkles":"✨","moon":"🌙","sun":"☀️","cloud":"☁️","camera":"📷"]
        var spaces: [ImportedSpace] = []; var untitled = 0
        for (k, v) in pairs(main["spaces"]) {
            guard let s = v as? Obj else { continue }
            let id = s["id"] as? String ?? k as? String ?? "space-\(spaces.count)"
            var roots: [String: String] = [:]
            for key in ["containerIDs", "newContainerIDs"] {
                for (k, v) in pairs(s[key]) { if let l = label(k), let v = v as? String { roots[l] = v } }
            }
            let custom = obj(s["customInfo"]), icon = obj(obj(s["customInfo"])["iconType"]), theme = obj(custom["windowTheme"])
            var emoji = nonempty(icon["emoji_v2"]) ?? nonempty(icon["emoji"])
            if emoji == nil, let n = icon["emoji"] as? Int, let scalar = UnicodeScalar(n) { emoji = String(scalar) }
            if emoji == nil, let name = icon["icon"] as? String { emoji = icons[name.lowercased().filter { $0.isASCII && $0.isLetter }] }
            var name = nonempty(s["title"])
            if name == nil {
                if id == "thebrowser.company.defaultPersonalSpaceID" { name = "Personal" }
                else { untitled += 1; name = "Space \(untitled)" }
            }
            let color = colors(obj(theme["primaryColorPalette"])["midTone"]).first ?? colors(theme["background"]).first ?? colors(theme).first ?? "#8edcc0"
            spaces.append(.init(id: id, name: name!, emoji: emoji ?? "•", icon: jsonValue(custom["iconType"]), theme: .init(color: color, colors: colors(theme["background"] ?? theme), raw: jsonValue(custom["windowTheme"])), profileID: profileID(s["profile"]), pinned: roots["pinned"].map { children(index, $0) } ?? [], today: includeToday ? roots["unpinned"].map { children(index, $0, keepSplits: false).flatMap(\.tabs) } ?? [] : []))
        }
        var favorites: [String: [ImportedTab]] = [:]
        var favoriteItems: [String: [ImportedItem]] = [:]
        func readFavorites(_ list: Any?, _ index: Index) {
            for (marker, value) in pairs(list) {
                guard let id = value as? String else { continue }
                // Favorites are tabs and (SV-2) splits; anything else comes in as its tabs.
                let items = children(index, id).flatMap { i -> [ImportedItem] in
                    if case .split = i { return [i] }
                    return i.tabs.map { .tab($0) }
                }
                let tabs = items.flatMap(\.tabs)
                if !tabs.isEmpty {
                    favorites[profileID(marker), default: []] += tabs
                    favoriteItems[profileID(marker), default: []] += items
                }
            }
        }
        readFavorites(main["topAppsContainerIDs"], index)
        if favorites.isEmpty {
            let sync = obj(root["sidebarSyncState"]), container = obj(obj(root["sidebarSyncState"])["container"])
            let items = (sync["items"] as? [Any] ?? []).map { v -> Any in
                let o = obj(v); return o["id"] == nil ? o["value"] ?? v : v
            }
            readFavorites(obj(container["value"] ?? container)["topAppsContainerIDs"], Index(items))
        }
        if spaces.isEmpty { warn(.emptySpaces, "No Spaces found in the file.") }
        if index.items.isEmpty { warn(.emptyItems, "The file contains no sidebar items.") }
        let ids = Set(spaces.map(\.profileID)).union(favorites.keys).sorted()
        let hasFavoriteSplit = favoriteItems.values.contains { $0.contains { if case .split = $0 { return true }; return false } }
        return .init(profiles: ids.map { .init(id: $0, directory: $0 == "default" ? "Default" : $0, name: $0 == "default" ? "Default" : $0, isAvailable: false) }, spaces: spaces, favorites: favorites, warnings: warnings,
                     favoriteItems: hasFavoriteSplit ? favoriteItems : nil)
    }
}

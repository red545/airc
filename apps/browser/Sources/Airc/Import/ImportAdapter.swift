// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import Foundation

// Turns AircImport's plan (what Arc has) into AircKit's blueprint (what Airc stores). The plan's IDs become source
// IDs, so a second import updates instead of duplicating (IM-1).

extension JSONValue {
    /// The value as `JSONSerialization` would return it, for AircKit's Arc theme reader.
    var foundation: Any {
        switch self {
        case .object(let o): o.mapValues(\.foundation)
        case .array(let a): a.map(\.foundation)
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        }
    }
}

enum ImportAdapter {
    static func profileKey(_ p: ImportedProfile) -> String { "arc-profile:" + p.directory }
    static func profileKey(id: String, in plan: ImportPlan) -> String {
        if let p = plan.profiles.first(where: { $0.id == id }) { return profileKey(p) }
        return "arc-profile:" + (id == "default" ? "Default" : id)
    }

    static func blueprint(from plan: ImportPlan) -> ImportBlueprint {
        // A profile's emoji: Arc has none, so use its first Space's.
        var firstEmoji: [String: String] = [:]
        for s in plan.spaces where firstEmoji[s.profileID] == nil && s.emoji != "•" { firstEmoji[s.profileID] = s.emoji }
        var firstTheme: [String: SpaceTheme] = [:]
        for s in plan.spaces where firstTheme[s.profileID] == nil { firstTheme[s.profileID] = theme(s.theme) }

        let profiles = plan.profiles.map { p in
            ImportBlueprint.Profile(sourceID: profileKey(p), name: p.name == "Default" && p.id == "default" ? "Personal" : p.name,
                                    emoji: firstEmoji[p.id] ?? "",
                                    color: ArcTheme.chromiumColor(p.color?.foundation) ?? firstTheme[p.id]?.colors.first,
                                    isSourceDefault: p.id == "default" || p.directory == "Default")
        }
        let spaces = plan.spaces.map { s in
            ImportBlueprint.Space(sourceID: "arc-space:" + s.id, name: s.name, icon: s.emoji == "•" ? nil : .emoji(s.emoji),
                                  theme: theme(s.theme), profileSourceID: profileKey(id: s.profileID, in: plan),
                                  pinned: s.pinned.map(node), today: s.today.map(tab))
        }
        var favorites: [String: [ImportBlueprint.Tab]] = [:]
        for (pid, tabs) in plan.favorites { favorites[profileKey(id: pid, in: plan), default: []] += tabs.map(tab) }
        // SV-2: Favorite splits stay splits.
        var favoriteNodes: [String: [ImportBlueprint.Node]] = [:]
        for (pid, items) in plan.favoriteItems ?? [:] { favoriteNodes[profileKey(id: pid, in: plan), default: []] += items.map(node) }
        return ImportBlueprint(profiles: profiles, spaces: spaces, favorites: favorites, favoriteNodes: favoriteNodes)
    }

    static func theme(_ t: ImportedTheme) -> SpaceTheme {
        ArcTheme.theme(from: t.raw?.foundation, fallbackColors: t.colors.isEmpty ? [t.color] : t.colors)
    }

    static func node(_ i: ImportedItem) -> ImportBlueprint.Node {
        switch i {
        case .tab(let t): .tab(tab(t))
        case .folder(let f): .folder(.init(sourceID: "arc-item:" + f.id, title: f.title, children: f.children.map(node)))
        case .split(let x):
            .split(.init(sourceID: "arc-item:" + x.id, title: x.title, axis: x.axis == "vertical" ? .vertical : .horizontal,
                         shares: x.shares, focusedSourceID: x.focusedID.map { "arc-item:" + $0 }, tabs: x.tabs.map(tab)))
        }
    }

    static func tab(_ t: ImportedTab) -> ImportBlueprint.Tab {
        // Arc stores dates as seconds since 2001 (Core Data's reference date).
        .init(sourceID: "arc-item:" + t.id, url: t.url, title: t.title, pageTitle: t.pageTitle,
              lastActiveAt: t.lastActiveAt.map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    /// The plan's warnings as one short, plain note for the user (IM-1), or nil when there's nothing to say.
    static func note(for warnings: [ImportWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        var counts: [ImportWarning.Code: Int] = [:]
        for w in warnings { counts[w.code, default: 0] += 1 }
        var parts: [String] = []
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : "\(n) \(many)" }
        if let n = counts[.splitView] { parts.append(plural(n, "A split view became separate tabs", "split views became separate tabs")) }
        if let n = counts[.easel] { parts.append(plural(n, "An Easel was skipped", "Easels were skipped")) }
        if let n = counts[.unsupportedItem] { parts.append(plural(n, "An item Airc doesn't have yet was flattened", "items Airc doesn't have yet were flattened")) }
        if let n = counts[.invalidTab] { parts.append(plural(n, "A tab without an address was left out", "tabs without an address were left out")) }
        if (counts[.missingItem] ?? 0) + (counts[.cycle] ?? 0) + (counts[.depthLimit] ?? 0) > 0 {
            parts.append("Some damaged sidebar entries were left out")
        }
        if counts[.missingProfile] != nil { parts.append("A profile folder is missing, so its logins can't come along") }
        if counts[.newerVersion] != nil { parts.append("This Arc is newer than Airc knows; everything readable came over") }
        return parts.isEmpty ? nil : parts.joined(separator: ". ") + "."
    }
}

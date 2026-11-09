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

        var profiles = plan.profiles.map { p in
            ImportBlueprint.Profile(sourceID: profileKey(p), name: p.name == "Default" && p.id == "default" ? "Personal" : p.name,
                                    emoji: firstEmoji[p.id] ?? "",
                                    color: ArcTheme.chromiumColor(p.color?.foundation) ?? firstTheme[p.id]?.colors.first,
                                    isSourceDefault: p.id == "default" || p.directory == "Default")
        }
        let spaces = plan.spaces.map { s in
            ImportBlueprint.Space(sourceID: "arc-space:" + s.id, name: s.name, icon: s.emoji == "•" ? nil : .emoji(s.emoji),
                                  theme: theme(s.theme), profileSourceID: profileKey(id: s.profileID, in: plan),
                                  pinned: s.pinned.map { node($0) }, today: s.today.map { tab($0) })
        }
        // Every profile a Space uses gets a profile, even one Arc's profile list doesn't have (a missing folder): without
        // it, applyImport would put that Space in the default profile, with the default profile's logins.
        let known = Set(profiles.map(\.sourceID))
        var added = Set<String>()
        for s in spaces where !known.contains(s.profileSourceID) && added.insert(s.profileSourceID).inserted {
            profiles.append(placeholderProfile(s.profileSourceID, spaces: spaces.filter { $0.profileSourceID == s.profileSourceID }))
        }
        var favorites: [String: [ImportBlueprint.Tab]] = [:]
        for (pid, tabs) in plan.favorites { favorites[profileKey(id: pid, in: plan), default: []] += tabs.map { tab($0) } }
        // SV-2: Favorite splits stay splits.
        var favoriteNodes: [String: [ImportBlueprint.Node]] = [:]
        for (pid, items) in plan.favoriteItems ?? [:] { favoriteNodes[profileKey(id: pid, in: plan), default: []] += items.map { node($0) } }
        return ImportBlueprint(profiles: profiles, spaces: spaces, favorites: favorites, favoriteNodes: favoriteNodes)
    }

    static func visits(_ plan: ImportPlan, profileIDs: [String: String]) -> [HistoryEntry] {
        plan.mappedHistory(profileIDs: profileIDs).flatMap { pid, visits -> [HistoryEntry] in
            return visits.map { HistoryEntry(profileID: pid, url: $0.url, title: $0.title,
                visitCount: $0.visitCount, typedCount: $0.typedCount, lastVisit: $0.lastVisit) }
        }
    }

    static func theme(_ t: ImportedTheme) -> SpaceTheme {
        ArcTheme.theme(from: t.raw?.foundation, fallbackColors: t.colors.isEmpty ? [t.color] : t.colors)
    }

    /// `prefix` makes the plan's IDs source keys ("arc-item:"); other browsers' plans have full keys already ("").
    static func node(_ i: ImportedItem, prefix: String = "arc-item:") -> ImportBlueprint.Node {
        switch i {
        case .tab(let t): .tab(tab(t, prefix: prefix))
        case .folder(let f): .folder(.init(sourceID: prefix + f.id, title: f.title, children: f.children.map { node($0, prefix: prefix) }))
        case .split(let x):
            .split(.init(sourceID: prefix + x.id, title: x.title, axis: x.axis == "vertical" ? .vertical : .horizontal,
                         shares: x.shares, focusedSourceID: x.focusedID.map { prefix + $0 }, tabs: x.tabs.map { tab($0, prefix: prefix) }))
        }
    }

    static func tab(_ t: ImportedTab, prefix: String = "arc-item:") -> ImportBlueprint.Tab {
        // Arc stores dates as seconds since 2001 (Core Data's reference date).
        .init(sourceID: prefix + t.id, url: t.url, title: t.title, pageTitle: t.pageTitle,
              lastActiveAt: t.lastActiveAt.map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    /// A profile for a Space whose profile isn't in Arc's profile list: named after its folder, with the first Space's
    /// emoji and colour.
    static func placeholderProfile(_ key: String, spaces: [ImportBlueprint.Space]) -> ImportBlueprint.Profile {
        let directory = key.hasPrefix("arc-profile:") ? String(key.dropFirst("arc-profile:".count)) : key
        let isDefault = directory == "Default"
        return ImportBlueprint.Profile(sourceID: key, name: isDefault ? "Personal" : directory,
                                       emoji: spaces.lazy.compactMap(\.emoji).first ?? "", color: spaces.first?.theme.colors.first,
                                       isSourceDefault: isDefault)
    }

    /// One thing the import changes on the way, said plainly: "1 Easel was left out".
    struct Change: Equatable, Identifiable {
        var count: Int
        /// The short line ("1 Easel was left out").
        var summary: String
        /// Why, for the Details popover ("Airc has no Easels.").
        var detail: String
        var id: String { summary }
    }

    /// The plan's warnings as plain changes, most important first (IM-1). Warnings never carry titles or URLs, so
    /// neither do these.
    static func changes(for warnings: [ImportWarning]) -> [Change] {
        var counts: [String: Int] = [:]
        for w in warnings {
            let key = w.code == .unsupportedItem ? "unsupported:" + (w.kind ?? "") : w.code.rawValue
            counts[key, default: 0] += 1
        }
        func n(_ k: String) -> Int { counts[k] ?? 0 }
        var out: [Change] = []
        func add(_ count: Int, _ one: String, _ many: String, _ detail: String) {
            guard count > 0 else { return }
            out.append(Change(count: count, summary: "\(count) " + (count == 1 ? one : many), detail: detail))
        }
        add(n("unreadableHistory"), "profile’s history couldn’t be read", "profiles’ history couldn’t be read", "Quit Arc and import again. Its Spaces still came over.")
        add(n("historyNeedsCheckpoint"), "profile may have newer history in Arc", "profiles may have newer history in Arc", "Arc is open (or didn't quit cleanly), and its latest visits wait in a file Airc doesn't read while Arc uses it. Quit Arc and import again: they're added, nothing is duplicated.")
        add(n("unreadableExtensions"), "profile’s extension list couldn’t be fully read", "profiles’ extension lists couldn’t be fully read", "Quit Arc and import again. Check Arc for anything missing.")
        add(n("easel"), "Easel was left out", "Easels were left out", "Airc has no Easels. Arc keeps them until Dec 22; export the ones you need from Arc first.")
        add(n("note"), "Note was left out", "Notes were left out", "Airc has no Notes yet. Copy what you need out of Arc's Notes first.")
        add(n("liveFolder"), "live folder is now a plain folder", "live folders are now plain folders",
            "Their tabs came over, but they no longer fill themselves from GitHub or Linear.")
        add(n("unsupported:tabGroup"), "tab group became single tabs", "tab groups became single tabs",
            "Airc has no tab groups; each tab in one is its own pinned tab now, in the same place.")
        add(n("splitView"), "split view became separate tabs", "split views became separate tabs",
            "Split views in Today, or inside another split, come over as their tabs one by one.")
        add(n("invalidTab"), "tab without an address was left out", "tabs without an address were left out",
            "Arc had saved these with no page address, so there was nothing to open.")
        let damaged = n("missingItem") + n("cycle") + n("depthLimit")
        add(damaged, "damaged sidebar entry was left out", "damaged sidebar entries were left out",
            "Arc's sidebar file points at entries that aren't there, or loops back on itself.")
        let other = counts.filter { $0.key.hasPrefix("unsupported:") && $0.key != "unsupported:tabGroup" }
        if !other.isEmpty {
            let kinds = other.keys.map { String($0.dropFirst("unsupported:".count)) }.filter { !$0.isEmpty }.sorted()
            let total = other.values.reduce(0, +)
            let names = kinds.joined(separator: ", ")
            add(total, "item of a kind Airc doesn't have yet became the tabs in it",
                "items of kinds Airc doesn't have yet became the tabs in them",
                "Anything inside them came over in their place" + (kinds.isEmpty ? "." : " (Arc calls them: " + names + ")."))
        }
        add(n("missingProfile"), "Arc profile folder is missing", "Arc profile folders are missing",
            "Its Spaces come over, but its history, extensions, logins and cookies can't: they live in that folder.")
        add(n("profileOutsideArc"), "profile folder links outside Arc's folder", "profile folders link outside Arc's folder",
            "Its Spaces come over. Airc reads only inside Arc's own folder, so its history and extensions didn't.")
        if n("unreadableProfileList") > 0 {
            out.append(Change(count: 1, summary: "Arc's profile list is damaged",
                              detail: "Profiles are named after their folders (\u{201C}Profile 1\u{201D}); everything in them still came over. Rename them in Settings › Profiles."))
        }
        if n("newerVersion") > 0 {
            out.append(Change(count: 1, summary: "This Arc is newer than Airc knows",
                              detail: "Everything Airc could read came over; check your Spaces once they're in."))
        }
        return out
    }
}

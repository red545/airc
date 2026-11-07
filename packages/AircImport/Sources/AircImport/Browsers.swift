// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Other browsers (IM-4): bookmarks and history only. Their saved passwords never come from their own stores or
// Keychain items; they come from a CSV file the user exported (PasswordCSV.swift). Nothing here reads a "Safe
// Storage" item, a `Login Data` or a `Cookies` database, and nothing decrypts anything.

/// A browser Airc imports bookmarks and history from.
public enum BrowserKind: String, Codable, Sendable, CaseIterable {
    case chrome, brave, edge, vivaldi, opera, chromium, dia, helium, firefox, zen, safari

    public enum Family: String, Sendable { case chromium, firefox, safari }

    public var family: Family {
        switch self {
        case .firefox, .zen: .firefox
        case .safari: .safari
        default: .chromium
        }
    }

    /// The short name the UI uses ("Chrome", "Edge").
    public var name: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .dia: "Dia"
        case .helium: "Helium"
        case .firefox: "Firefox"
        case .zen: "Zen"
        case .safari: "Safari"
        }
    }

    /// A colour for the browser's Space when its profile has none (#rrggbb).
    public var color: String {
        switch self {
        case .chrome, .chromium: "#7EA6E8"
        case .brave: "#F2A27E"
        case .edge: "#6CC4D9"
        case .vivaldi: "#E8838A"
        case .opera: "#E57373"
        case .dia: "#A9B8F0"
        case .helium: "#9FD6C4"
        case .firefox: "#F5B072"
        case .zen: "#C3A8F0"
        case .safari: "#7FB8F0"
        }
    }
}

/// One installation's data folder (Chrome and Chrome Beta are two), with its profiles.
public struct BrowserInstall: Sendable, Equatable, Identifiable {
    /// Stable across launches: "chrome", "chrome-beta", "firefox". Prefixes the import's source IDs.
    public var id: String
    public var kind: BrowserKind
    /// "Chrome", "Chrome Beta".
    public var name: String
    /// The app's bundle identifiers, for its icon.
    public var bundleIDs: [String]
    public var folder: URL
    public var profiles: [BrowserProfile]
}

/// One profile of an installation.
public struct BrowserProfile: Sendable, Equatable, Identifiable {
    /// The profile's folder relative to the install's: "Default", "Profile 1"; Firefox's "Profiles/x.default-release";
    /// "" where the data folder is the profile (Opera).
    public var id: String
    /// The name the browser shows ("Work"), or the browser's own name when the profile has a default one ("Person 1").
    public var name: String
    /// The profile's own name was a default one: "Person 1", "Profile 2", Firefox's "default-release".
    public var hasDefaultName: Bool
    /// The avatar colour, if the browser keeps one (#rrggbb).
    public var color: String?
    /// The colour as Chromium stores it (a signed ARGB integer), for AircKit's reader.
    public var chromiumColor: Double?
    public var folder: URL
    /// The browser's own default profile ("Default"; Firefox's default one).
    public var isDefault: Bool
}

public enum BrowserImporter {
    struct Location {
        var id: String, kind: BrowserKind, name: String, path: String, bundleIDs: [String]
    }

    /// Where each browser keeps its data on macOS, under ~/Library/Application Support.
    static let locations: [Location] = [
        .init(id: "chrome", kind: .chrome, name: "Chrome", path: "Google/Chrome", bundleIDs: ["com.google.Chrome"]),
        .init(id: "chrome-beta", kind: .chrome, name: "Chrome Beta", path: "Google/Chrome Beta", bundleIDs: ["com.google.Chrome.beta"]),
        .init(id: "chrome-dev", kind: .chrome, name: "Chrome Dev", path: "Google/Chrome Dev", bundleIDs: ["com.google.Chrome.dev"]),
        .init(id: "chrome-canary", kind: .chrome, name: "Chrome Canary", path: "Google/Chrome Canary", bundleIDs: ["com.google.Chrome.canary"]),
        .init(id: "brave", kind: .brave, name: "Brave", path: "BraveSoftware/Brave-Browser", bundleIDs: ["com.brave.Browser"]),
        .init(id: "edge", kind: .edge, name: "Edge", path: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"]),
        .init(id: "vivaldi", kind: .vivaldi, name: "Vivaldi", path: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"]),
        .init(id: "opera", kind: .opera, name: "Opera", path: "com.operasoftware.Opera", bundleIDs: ["com.operasoftware.Opera"]),
        .init(id: "opera-gx", kind: .opera, name: "Opera GX", path: "com.operasoftware.OperaGX", bundleIDs: ["com.operasoftware.OperaGX"]),
        .init(id: "dia", kind: .dia, name: "Dia", path: "Dia/User Data", bundleIDs: ["company.thebrowser.dia"]),
        .init(id: "helium", kind: .helium, name: "Helium", path: "net.imput.helium", bundleIDs: ["net.imput.helium"]),
        .init(id: "chromium", kind: .chromium, name: "Chromium", path: "Chromium", bundleIDs: ["org.chromium.Chromium"]),
        .init(id: "firefox", kind: .firefox, name: "Firefox", path: "Firefox", bundleIDs: ["org.mozilla.firefox"]),
        .init(id: "zen", kind: .zen, name: "Zen", path: "zen", bundleIDs: ["app.zen-browser.zen"]),
    ]

    /// Every browser with importable data under `home` (its Library/Application Support), in a fixed order: Chrome and
    /// its channels, the other Chromium browsers, Firefox, Zen. Reads only each browser's profile list (`Local State`,
    /// `profiles.ini`) and checks which profile folders hold bookmarks or history. A folder macOS won't let Airc read
    /// is left out. Safari isn't listed: its library needs Full Disk Access, so it comes from an exported file.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserInstall] {
        let support = home.appendingPathComponent("Library/Application Support")
        return locations.compactMap { l in
            let folder = support.appendingPathComponent(l.path)
            guard isDirectory(folder) else { return nil }
            let profiles = l.kind.family == .firefox ? firefoxProfiles(folder, kind: l.kind) : chromiumProfiles(folder, kind: l.kind, name: l.name)
            guard !profiles.isEmpty else { return nil }
            return BrowserInstall(id: l.id, kind: l.kind, name: l.name, bundleIDs: l.bundleIDs, folder: folder, profiles: profiles)
        }
    }

    // MARK: Profiles

    /// Chromium's profile list: `Local State` → `profile.info_cache` (name, colour), in `profiles_order`. Only folders
    /// with a `Bookmarks` or `History` file count. Opera keeps its one profile in the data folder itself.
    static func chromiumProfiles(_ folder: URL, kind: BrowserKind, name browserName: String) -> [BrowserProfile] {
        var cache: Obj = [:]
        var order: [String] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Local State")), data.count < 64 << 20,
           let root = try? JSONSerialization.jsonObject(with: data) as? Obj {
            let profile = obj(root["profile"])
            cache = obj(profile["info_cache"])
            order = profile["profiles_order"] as? [String] ?? []
        }
        var dirs = order.filter { cache[$0] != nil }
        dirs += cache.keys.filter { !dirs.contains($0) }.sorted { a, b in
            a != b && (a == "Default" || (b != "Default" && a.localizedStandardCompare(b) == .orderedAscending))
        }
        if !dirs.contains("Default"), hasChromiumData(folder.appendingPathComponent("Default")) { dirs.insert("Default", at: 0) }
        var out: [BrowserProfile] = []
        for dir in dirs where (try? validateDirectory(dir)) != nil && !["System Profile", "Guest Profile"].contains(dir) {
            let path = folder.appendingPathComponent(dir)
            guard hasChromiumData(path) else { continue }
            let info = obj(cache[dir])
            let own = nonempty(info["name"])
            let generic = (info["is_using_default_name"] as? Bool) ?? own.map(isDefaultName) ?? true
            let raw = (info["profile_highlight_color"] ?? info["default_avatar_fill_color"]) as? NSNumber
            out.append(BrowserProfile(id: dir, name: (generic ? nil : own) ?? browserName, hasDefaultName: generic,
                                      color: raw.map { hex(argb: $0.int64Value) }, chromiumColor: raw?.doubleValue,
                                      folder: path, isDefault: dir == "Default"))
        }
        // Opera: the data folder is the profile.
        if out.isEmpty, hasChromiumData(folder) {
            out.append(BrowserProfile(id: "", name: browserName, hasDefaultName: true, color: nil, chromiumColor: nil, folder: folder, isDefault: true))
        }
        return out
    }

    static func hasChromiumData(_ profile: URL) -> Bool {
        isFile(profile.appendingPathComponent("Bookmarks")) || isFile(profile.appendingPathComponent("History"))
    }

    /// Firefox's (and Zen's) `profiles.ini`: `[ProfileN]` sections with `Name`, `Path` and `IsRelative`, the default from
    /// `[Install…] Default=` or `Default=1`. Only relative paths inside the data folder, with a `places.sqlite`.
    static func firefoxProfiles(_ folder: URL, kind: BrowserKind) -> [BrowserProfile] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profiles.ini")), data.count < 1 << 20,
              let text = String(data: data, encoding: .utf8) else { return [] }
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") { sections.append((String(line.dropFirst().dropLast()), [:])); continue }
            guard !sections.isEmpty, let eq = line.firstIndex(of: "="), !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            sections[sections.count - 1].values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let installDefault = sections.first { $0.name.hasPrefix("Install") }?.values["Default"]
        var out: [BrowserProfile] = []
        for s in sections where s.name.hasPrefix("Profile") {
            guard let path = s.values["Path"], s.values["IsRelative"] != "0", isSafeRelative(path) else { continue }
            let profile = folder.appendingPathComponent(path)
            guard isFile(profile.appendingPathComponent("places.sqlite")) else { continue }
            let own = nonempty(s.values["Name"])
            let generic = own.map(isDefaultName) ?? true
            out.append(BrowserProfile(id: path, name: (generic ? nil : own) ?? kind.name, hasDefaultName: generic, color: nil, chromiumColor: nil,
                                      folder: profile, isDefault: installDefault.map { $0 == path } ?? (s.values["Default"] == "1")))
        }
        // The default profile first, then the file's order.
        return out.filter(\.isDefault) + out.filter { !$0.isDefault }
    }

    /// The names browsers give profiles nobody named: "Person 1", "Profile 2", "Default", "Your Chrome", Firefox's
    /// "default-release".
    static func isDefaultName(_ name: String) -> Bool {
        let n = name.lowercased()
        if ["default", "default-release", "default-esr", "default-nightly", "your chrome", "user", "guest"].contains(n) { return true }
        return n.range(of: #"^(person|profile|user|default)[ -]?\d+$"#, options: .regularExpression) != nil
    }

    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    static func hex(argb: Int64) -> String {
        let u = UInt32(truncatingIfNeeded: argb)
        return String(format: "#%02x%02x%02x", (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF)
    }

    static func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    static func isFile(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// P10a (L02, L04): where Library › Media's files come from (Arc's "Show media from:"), and Archived Tabs' filters
// ("Where was the tab?", "How was the tab closed?"). Pure rules; the app reads folders and keeps the grants
// (Library/LibraryFolderSources.swift).

/// A folder the person can let the Library show (Arc: "Allow Arc to show your Documents, Desktop, and Download
/// Folders…", and its Screenshots folder).
public enum LibraryFolder: String, Codable, CaseIterable, Sendable, Identifiable {
    case desktop, documents, downloads, screenshots

    public var id: String { rawValue }

    /// As the menu and the permission notes name it.
    public var title: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads Folder"
        case .screenshots: "Screenshots"
        }
    }
}

/// What Settings keeps about the Library's sources (settings.json `librarySources`). Folder access is only ever what
/// the person granted in an open panel: a bookmark per folder, never a path Airc reads on its own.
public struct LibrarySourceSettings: Codable, Equatable, Sendable {
    public struct Grant: Codable, Equatable, Sendable {
        /// A security-scoped bookmark of the folder the person picked.
        public var bookmark: Data
        /// Where it was when granted (shown in the menu; the bookmark finds it if it moves).
        public var path: String
        public var grantedAt: Date

        public init(bookmark: Data, path: String, grantedAt: Date) {
            self.bookmark = bookmark
            self.path = path
            self.grantedAt = grantedAt
        }
    }

    /// Airc's own Captures (⇧⌘2) and downloads list, on by default (Arc's "Captures" and "Downloads" toggles).
    public var showCaptures: Bool
    public var showDownloads: Bool
    /// Folders granted, by `LibraryFolder.rawValue`.
    public var grants: [String: Grant]
    /// Granted folders turned off in the menu (kept granted, not shown).
    public var paused: Set<String>
    /// Folders the person said no to (cancelled the panel): the menu offers them again, nothing asks by itself.
    public var declined: Set<String>
    /// Files hidden from the Library ("Hide from Library"), by path. The files stay where they are.
    public var hidden: Set<String>

    public init(showCaptures: Bool = true, showDownloads: Bool = true, grants: [String: Grant] = [:], paused: Set<String> = [],
                declined: Set<String> = [], hidden: Set<String> = []) {
        self.showCaptures = showCaptures
        self.showDownloads = showDownloads
        self.grants = grants
        self.paused = paused
        self.declined = declined
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case showCaptures, showDownloads, grants, paused, declined, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LibrarySourceSettings()
        showCaptures = (try? c.decodeIfPresent(Bool.self, forKey: .showCaptures)) ?? d.showCaptures
        showDownloads = (try? c.decodeIfPresent(Bool.self, forKey: .showDownloads)) ?? d.showDownloads
        grants = (try? c.decodeIfPresent([String: Grant].self, forKey: .grants)) ?? [:]
        paused = (try? c.decodeIfPresent(Set<String>.self, forKey: .paused)) ?? []
        declined = (try? c.decodeIfPresent(Set<String>.self, forKey: .declined)) ?? []
        hidden = (try? c.decodeIfPresent(Set<String>.self, forKey: .hidden)) ?? []
    }

    public func grant(_ f: LibraryFolder) -> Grant? { grants[f.rawValue] }
    /// Granted and not turned off.
    public func shows(_ f: LibraryFolder) -> Bool { grants[f.rawValue] != nil && !paused.contains(f.rawValue) }

    public mutating func granted(_ f: LibraryFolder, _ g: Grant) {
        grants[f.rawValue] = g
        paused.remove(f.rawValue)
        declined.remove(f.rawValue)
    }

    public mutating func declined(_ f: LibraryFolder) {
        if grants[f.rawValue] == nil { declined.insert(f.rawValue) }
    }

    /// "Stop Showing": the grant goes (the bookmark is dropped), as if never given.
    public mutating func forget(_ f: LibraryFolder) {
        grants[f.rawValue] = nil
        paused.remove(f.rawValue)
        declined.remove(f.rawValue)
    }

    public mutating func setShown(_ f: LibraryFolder, _ on: Bool) {
        guard grants[f.rawValue] != nil else { return }
        if on { paused.remove(f.rawValue) } else { paused.insert(f.rawValue) }
    }
}

/// A folder source's state, as the menu and the notes over the grid show it.
public enum LibraryFolderState: Equatable, Sendable {
    /// Not asked yet: "Allow…".
    case notGranted
    /// The person said no: offered again, nothing asks by itself.
    case declined
    /// Granted and readable.
    case granted(path: String)
    /// Granted once, unreadable now: the folder is gone, moved where the bookmark can't follow, or access was taken back
    /// (System Settings › Privacy & Security › Files and Folders). "Choose Again…".
    case revoked(reason: String)

    public var isGranted: Bool { if case .granted = self { return true } else { return false } }
}

/// What the Library shows of a granted folder: its own pictures and videos at the top level, never the folders inside
/// it (not a crawler), newest first, at most `limit`.
public enum LibraryFolderListing {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var isHidden: Bool
        public var isPackage: Bool
        public var modified: Date
        public var size: Int64

        public init(name: String, isDirectory: Bool = false, isHidden: Bool = false, isPackage: Bool = false, modified: Date,
                    size: Int64 = 1) {
            self.name = name
            self.isDirectory = isDirectory
            self.isHidden = isHidden
            self.isPackage = isPackage
            self.modified = modified
            self.size = size
        }
    }

    public static let limit = 400

    /// `excluded`: paths that never show (a private window's downloads and Captures, files hidden from the Library).
    public static func files(_ folder: LibraryFolder, at path: String, entries: [Entry], excluded: Set<String> = [],
                             limit: Int = Self.limit) -> [LibraryFile] {
        let base = (path as NSString).standardizingPath
        let picked = entries.filter { e in
            !e.isDirectory && !e.isPackage && !e.isHidden && !e.name.hasPrefix(".") && e.size > 0
                && LibraryMedia.kind(name: e.name, mimeType: nil) != .other
        }
        var out: [LibraryFile] = []
        for e in picked.sorted(by: { a, b in a.modified != b.modified ? a.modified > b.modified : a.name < b.name }) {
            let p = (base as NSString).appendingPathComponent(e.name)
            guard !excluded.contains(p) else { continue }
            out.append(LibraryFile(id: "folder:\(folder.rawValue):\(p)", path: p, name: e.name, date: e.modified, source: .folder))
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Archived Tabs' filters (L02)

/// Arc's "Filter Archived Tabs": where the tab was (a Space, or Little Arc) and how it closed (by itself after the
/// archive time, or by you: ⌘W, Clear, a Space deleted).
public struct ArchiveFilter: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case anywhere
        case space(String)
        case littleArc
    }

    public enum Closing: Equatable, Sendable {
        case any
        /// Arc's "Auto-Closed".
        case automatic
        /// Arc's "Manually Closed".
        case manual
    }

    public var place: Place
    public var closing: Closing

    public init(place: Place = .anywhere, closing: Closing = .any) {
        self.place = place
        self.closing = closing
    }

    public var isActive: Bool { place != .anywhere || closing != .any }

    public func matches(_ e: ArchiveEntry) -> Bool {
        switch place {
        case .anywhere: break
        case .space(let id): if e.spaceID != id || e.origin == ArchiveEntry.littleArcOrigin { return false }
        case .littleArc: if e.origin != ArchiveEntry.littleArcOrigin { return false }
        }
        switch closing {
        case .any: return true
        case .automatic: return e.reason == .auto
        case .manual: return e.reason != .auto
        }
    }
}

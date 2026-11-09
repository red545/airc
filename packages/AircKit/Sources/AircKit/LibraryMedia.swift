// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

/// A file the Library knows about (LIB-1, Arc ref §2.9 and §5): a finished download from the engine's own downloads
/// list, a Capture saved with ⇧⌘2, or (P10a) a picture or video at the top of a folder the person let the Library show
/// (LibrarySources.swift). Never found by looking through folders on its own.
public struct LibraryFile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case download, capture, folder }
    public enum Kind: String, Sendable { case image, video, other }

    /// The download's row ID ("profile/guid") or the Capture's path.
    public var id: String
    public var path: String
    public var name: String
    /// When it was finished (the download's end, else its start) or saved.
    public var date: Date
    public var source: Source
    public var mimeType: String?
    /// A download that's still running, failed, was cancelled or waits for Keep: not a file yet.
    public var isComplete: Bool
    /// From a private window: never listed.
    public var isPrivate: Bool

    public init(id: String, path: String, name: String, date: Date, source: Source, mimeType: String? = nil,
                isComplete: Bool = true, isPrivate: Bool = false) {
        self.id = id
        self.path = path
        self.name = name
        self.date = date
        self.source = source
        self.mimeType = mimeType
        self.isComplete = isComplete
        self.isPrivate = isPrivate
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var kind: Kind { LibraryMedia.kind(name: name, mimeType: mimeType) }
}

/// Which files the Library's Media section and the Library button's recent files show.
public enum LibraryMedia {
    /// The hover list's length (Arc shows a handful).
    public static let recentLimit = 5

    /// Image or video by the file's type: its name's extension first (what Finder and Quick Look go by), then the MIME
    /// type the server sent. Audio, PDFs and everything else are `other`.
    public static func kind(name: String, mimeType: String?) -> LibraryFile.Kind {
        let ext = (name as NSString).pathExtension
        // A known extension decides (a .pdf served as image/png stays a PDF); an unknown one or none asks the MIME type.
        if !ext.isEmpty, let t = UTType(filenameExtension: ext), !t.isDynamic { return kind(of: t) ?? .other }
        if let m = mimeType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
           let t = UTType(mimeType: m), let k = kind(of: t) {
            return k
        }
        return .other
    }

    private static func kind(of t: UTType) -> LibraryFile.Kind? {
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) { return .video }
        return nil
    }

    /// Library › Media: images and videos, newest first, that still exist.
    public static func media(_ files: [LibraryFile], exists: (String) -> Bool) -> [LibraryFile] {
        listed(files, exists: exists).filter { $0.kind != .other }
    }

    /// The Library button's hover list: the newest downloads and Captures of any type that still exist.
    public static func recent(_ files: [LibraryFile], limit: Int = recentLimit, exists: (String) -> Bool) -> [LibraryFile] {
        Array(listed(files, exists: exists).prefix(limit))
    }

    /// Finished, not private, newest first, one entry per file (a file downloaded twice under one name, or a Capture
    /// saved over: the newest), and only files that are still where they were written.
    static func listed(_ files: [LibraryFile], exists: (String) -> Bool) -> [LibraryFile] {
        let ordered = files.filter { $0.isComplete && !$0.isPrivate && !$0.path.isEmpty }.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.id > b.id
        }
        var seen = Set<String>()
        var out: [LibraryFile] = []
        for f in ordered {
            let key = (f.path as NSString).standardizingPath
            guard seen.insert(key).inserted, exists(f.path) else { continue }
            out.append(f)
        }
        return out
    }
}

/// Captures saved with ⇧⌘2 (CB-5), as the Library lists them: path and time, newest last, at most `limit`. Private
/// windows' Captures are never recorded. Kept as JSON in the app's data folder (LibraryFiles in the app).
public struct CaptureRecords: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var date: Date
        public init(path: String, date: Date) {
            self.path = path
            self.date = date
        }
    }

    public static let limit = 500
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// A Capture was saved at `path` (a save over an earlier one replaces its entry).
    public mutating func add(path: String, date: Date) {
        entries.removeAll { $0.path == path }
        entries.append(Entry(path: path, date: date))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Forgets files that are gone (at launch: a file moved to the Trash during a session can still come back by Undo).
    /// True when something was removed.
    @discardableResult
    public mutating func prune(exists: (String) -> Bool) -> Bool {
        let before = entries.count
        entries.removeAll { !exists($0.path) }
        return entries.count != before
    }

    public var files: [LibraryFile] {
        entries.map { LibraryFile(id: "capture:" + $0.path, path: $0.path, name: ($0.path as NSString).lastPathComponent,
                                  date: $0.date, source: .capture, mimeType: "image/png") }
    }
}

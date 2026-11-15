// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ArchiveScope: Sendable {
    case all, profile(String), space(String)

    public func contains(_ entry: ArchiveEntry) -> Bool {
        switch self {
        case .all: return true
        case .profile(let id): return entry.profileID == id
        case .space(let id): return entry.spaceID == id
        }
    }
}


/// LIB-2: which archived tabs Clear Archive removes. Arc cleared everything; Airc also offers the older ones only, so
/// the Archive can be cleared now and then without losing this week's tabs.
public enum ArchiveClearAge: Int, CaseIterable, Sendable {
    case everything = 0, olderThan7Days = 7, olderThan30Days = 30

    public var title: String {
        switch self {
        case .everything: "Everything"
        case .olderThan7Days: "Older than 7 days"
        case .olderThan30Days: "Older than 30 days"
        }
    }

    /// Archived before `now` minus the age (everything: always).
    public func includes(_ entry: ArchiveEntry, now: Date) -> Bool {
        self == .everything || entry.archivedAt < now.addingTimeInterval(-Double(rawValue) * 86400)
    }
}

/// What one Clear Archive removed: the Library keeps it while its Undo toast shows, then drops it.
public struct ClearedArchive: Sendable, Equatable {
    public let entries: [ArchiveEntry]
    public let age: ArchiveClearAge
    public var count: Int { entries.count }
}

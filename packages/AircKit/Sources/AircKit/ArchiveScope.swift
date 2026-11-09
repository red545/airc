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


// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

public struct LittleArcProfiles: Codable, Equatable, Sendable {
    public private(set) var domains: [String: String] = [:]
    public init() {}

    public mutating func remember(_ profileID: String, for url: URL?) {
        guard let key = BoostDomain.key(for: url) else { return }
        domains[key] = profileID
    }

    /// Explicit ATC rules outrank memory; removed profiles/Spaces fall back to the caller's recent Space.
    public func space(for url: URL, rules: [LinkRule], spaces: [Space], recentSpaceID: String) -> String {
        if let rule = LinkRouting.space(for: url, rules: rules, existingSpaces: Set(spaces.map(\.id))) { return rule }
        guard let key = BoostDomain.key(for: url), let profile = domains[key] else { return recentSpaceID }
        return spaces.first { $0.id == recentSpaceID && $0.profileID == profile }?.id
            ?? spaces.first { $0.profileID == profile }?.id ?? recentSpaceID
    }
}

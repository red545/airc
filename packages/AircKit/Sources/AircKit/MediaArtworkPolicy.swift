// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// App-side artwork has no access to the private profile's network context. Only inline images
/// may leave that context; callers decode them in memory, never through a persistent cache.
public enum MediaArtworkPolicy {
    public static func source(_ urls: [String], ordinaryTab: Bool = false) -> String? {
        urls.first { value in
            let scheme = URL(string: value)?.scheme?.lowercased()
            return scheme == "data" || (ordinaryTab && (scheme == "https" || scheme == "http"))
        }
    }
}

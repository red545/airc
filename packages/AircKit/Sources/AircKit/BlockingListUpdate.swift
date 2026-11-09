// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure update decisions. The browser supplies transport and atomic file I/O;
/// tests supply responses and clocks without contacting list hosts.
public enum BlockingListUpdate {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var etag: String?
        public var lastModified: String?
        public var expires: Date?
        public init(status: Int, body: Data = Data(), etag: String? = nil, lastModified: String? = nil, expires: Date? = nil) {
            self.status = status; self.body = body; self.etag = etag; self.lastModified = lastModified; self.expires = expires
        }
    }
    public enum Result: Equatable, Sendable {
        case unchanged(BlockingListVersion)
        case candidate(Data, BlockingListMetadata)
    }
    public enum UpdateError: Error, Equatable {
        case status(Int), notModifiedWithoutCache, staleVersion
    }

    /// Returns a candidate, never installs it. Conversion/compilation must
    /// succeed before callers atomically replace the last good version.
    public static func evaluate(_ response: Response, current: BlockingListVersion?, now: Date) throws -> Result {
        if response.status == 304 {
            guard var current else { throw UpdateError.notModifiedWithoutCache }
            current.notModified(at: now, etag: response.etag, lastModified: response.lastModified, httpExpires: response.expires)
            return .unchanged(current)
        }
        guard response.status == 200 else { throw UpdateError.status(response.status) }
        let metadata = try BlockingListMetadata.parse(response.body)
        // Numeric upstream timestamps can be ordered. Arbitrary version strings
        // cannot: bytes/digest still define identity, including changed same-version files.
        if let old = current?.metadata.version, let new = metadata.version,
           old.count == new.count, old.allSatisfy(\.isNumber), new.allSatisfy(\.isNumber), new < old {
            throw UpdateError.staleVersion
        }
        return .candidate(response.body, metadata)
    }

    /// Bounded retry without turning an error into the next successful-check
    /// timestamp. Exponential backoff is transient, not persisted request history.
    public static func retryDelay(failures: Int) -> TimeInterval {
        min(24 * 3600, 3600 * pow(2, Double(max(0, min(failures, 6) - 1))))
    }
}

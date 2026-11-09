// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Subscription metadata, independent of the filter engine's syntax parser.
/// A failed fetch/parse must leave the current, compiled version in service.
public struct BlockingListMetadata: Codable, Equatable, Sendable {
    public static let refreshInterval: TimeInterval = 4 * 24 * 60 * 60
    public static let maxBytes = 32 * 1024 * 1024
    public var title: String?
    public var version: String?
    public var expires: TimeInterval

    public enum ParseError: Error, Equatable { case tooLarge, invalidUTF8, invalidHeader, emptyRules }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw ParseError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw ParseError.invalidUTF8 }
        if text.first == "\u{feff}" { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("[Adblock Plus "), first.hasSuffix("]") else { throw ParseError.invalidHeader }
        var value = Self(title: nil, version: nil, expires: refreshInterval)
        // Only headers can supply metadata, never comments embedded in the body.
        for line in lines.dropFirst() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("!") else { break }
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(after: line.startIndex)..<split].trimmingCharacters(in: .whitespaces).lowercased()
            let content = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content.utf8.count <= 1024 else { continue }
            switch key {
            case "title" where value.title == nil: value.title = content
            case "version" where value.version == nil: value.version = content
            case "expires":
                if let duration = expiry(content) { value.expires = duration }
            default: break
            }
        }
        guard lines.dropFirst().contains(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("!") && !line.hasPrefix("[")
        }) else { throw ParseError.emptyRules }
        return value
    }

    private static func expiry(_ input: String) -> TimeInterval? {
        let fields = input.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, let quantity = Double(fields[0]), quantity.isFinite, quantity > 0 else { return nil }
        let multiplier: Double
        switch fields[1] {
        case "hour", "hours": multiplier = 3600
        case "day", "days": multiplier = 86400
        default: return nil
        }
        let value = quantity * multiplier
        guard value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// Cache identity includes the exact bytes and converter schema, not just the
/// author's advisory Version header. Identical headers can accompany new rules.
public struct BlockingListVersion: Codable, Equatable, Sendable {
    public var digest: String
    public var converterVersion: UInt32
    public var metadata: BlockingListMetadata
    public var etag: String?
    public var lastModified: String?
    public var checkedAt: Date
    public var httpExpires: Date?

    public init(digest: String, converterVersion: UInt32, metadata: BlockingListMetadata,
                etag: String? = nil, lastModified: String? = nil, checkedAt: Date, httpExpires: Date? = nil) {
        self.digest = digest; self.converterVersion = converterVersion; self.metadata = metadata
        self.etag = Self.safeValidator(etag); self.lastModified = Self.safeValidator(lastModified)
        self.checkedAt = checkedAt; self.httpExpires = httpExpires
    }

    public var cacheKey: String { "v\(converterVersion)-\(digest)" }
    public var nextRefresh: Date {
        // Never poll more frequently than the accepted four-day cadence, and
        // respect a list's longer Expires directive. Explicit Update Now differs.
        max(checkedAt.addingTimeInterval(max(BlockingListMetadata.refreshInterval, metadata.expires)), httpExpires ?? .distantPast)
    }
    public var conditionalHeaders: [String: String] {
        if let etag = Self.safeValidator(etag) { return ["If-None-Match": etag] }
        if let modified = Self.safeValidator(lastModified) { return ["If-Modified-Since": modified] }
        return [:]
    }
    public mutating func notModified(at date: Date, etag: String? = nil, lastModified: String? = nil, httpExpires: Date? = nil) {
        checkedAt = date
        if let httpExpires { self.httpExpires = httpExpires }
        if let etag = Self.safeValidator(etag) { self.etag = etag }
        if let modified = Self.safeValidator(lastModified) { self.lastModified = modified }
    }
    private static func safeValidator(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return value
    }
}

/// Persist only ordinary-profile settings. Private exceptions belong to an
/// in-memory window/context overlay owned by the browser layer.
public struct BlockingProfileConfiguration: Codable, Equatable, Sendable {
    public var enabled = true
    public private(set) var hasExplicitChoice = false
    public private(set) var defaultMigrationVersion = 1
    public var blockThirdPartyCookies = false
    public var selectedLists: Set<String> = ["easylist", "easyprivacy"]
    public var exceptions: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, hasExplicitChoice, defaultMigrationVersion, blockThirdPartyCookies, selectedLists, exceptions
    }
    private enum LegacyKeys: String, CodingKey { case offered }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        // The earlier offer implementation also set `offered` when a user
        // switched protection off. Preserve that choice when upgrading it.
        hasExplicitChoice = try values.decodeIfPresent(Bool.self, forKey: .hasExplicitChoice)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .offered) ?? false
        defaultMigrationVersion = try values.decodeIfPresent(Int.self, forKey: .defaultMigrationVersion) ?? 0
        blockThirdPartyCookies = try values.decodeIfPresent(Bool.self, forKey: .blockThirdPartyCookies) ?? false
        selectedLists = try values.decodeIfPresent(Set<String>.self, forKey: .selectedLists) ?? ["easylist", "easyprivacy"]
        exceptions = try values.decodeIfPresent(Set<String>.self, forKey: .exceptions) ?? []
    }
    public mutating func migrateDefault() {
        guard defaultMigrationVersion < 1 else { return }
        if !hasExplicitChoice { enabled = true }
        defaultMigrationVersion = 1
    }
    public mutating func setEnabled(_ value: Bool) {
        enabled = value; hasExplicitChoice = true
    }

    public static func host(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
    public func blocks(_ url: URL, privateExceptions: Set<String>? = nil) -> Bool {
        guard enabled, let host = Self.host(for: url) else { return false }
        return !(privateExceptions ?? exceptions).contains(host)
    }
}

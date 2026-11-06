// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A lossless, Sendable JSON value for version-dependent Arc theme fields.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
public struct ImportedTab: Codable, Sendable, Equatable {
    public var id: String
    public var url: String
    public var title: String?
    public var pageTitle: String?
    public var lastActiveAt: Double?
}
public struct ImportedFolder: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var children: [ImportedItem]
}
/// SV-2: an Arc split view of 2–4 tabs in pinned tabs or Favorites (`SidebarSplitViewData`).
public struct ImportedSplit: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    /// "horizontal" (side by side) or "vertical" (stacked).
    public var axis: String
    /// Each tab's width factor, in tab order (0 where Arc has none).
    public var shares: [Double]
    public var focusedID: String?
    public var tabs: [ImportedTab]
}
public enum ImportedItem: Codable, Sendable, Equatable {
    case tab(ImportedTab), folder(ImportedFolder), split(ImportedSplit)
    public var tabs: [ImportedTab] {
        switch self {
        case .tab(let t): return [t]
        case .folder(let f): return f.children.flatMap(\.tabs)
        case .split(let x): return x.tabs
        }
    }
}
public struct ImportedTheme: Codable, Sendable, Equatable {
    public var color: String
    public var colors: [String]
    /// Exact source theme, including gradients, intensity and grain.
    public var raw: JSONValue?
}
public struct ImportedSpace: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var emoji: String
    public var icon: JSONValue?
    public var theme: ImportedTheme
    public var profileID: String
    public var pinned: [ImportedItem]
    public var today: [ImportedTab]
}
public struct ImportedProfile: Codable, Sendable, Equatable {
    public var id: String
    public var directory: String
    public var name: String
    public var avatar: String?
    public var color: JSONValue?
    public var isAvailable: Bool
}
public struct ImportWarning: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable { case splitView, unsupportedItem, easel, note, liveFolder, missingItem, invalidTab, cycle, depthLimit, emptySpaces, emptyItems, newerVersion, missingProfile }
    public var code: Code
    /// Deliberately excludes source titles, URLs and identifiers.
    public var message: String
    /// For `unsupportedItem`: Arc's name for the item's kind (`tabGroup`, `sharedObject`…), never anything the user wrote.
    public var kind: String? = nil

    public init(code: Code, message: String, kind: String? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
    }
}
public struct ImportPlan: Codable, Sendable, Equatable {
    public var profiles: [ImportedProfile]
    public var spaces: [ImportedSpace]
    /// Every Favorite tab, flat (a Favorite split's tabs one after another).
    public var favorites: [String: [ImportedTab]]
    public var warnings: [ImportWarning]
    /// SV-2: the Favorites with their splits kept, in order; nil when no profile has a Favorite split.
    public var favoriteItems: [String: [ImportedItem]]? = nil
}
public enum ImportError: Error, LocalizedError, Sendable, Equatable {
    case arcNotInstalled, noData, permissionDenied, invalidSidebar, invalidLocalState
    case keychainDeclined, keychainUnavailable, unsupportedEncryption, decryptionFailed, databaseFailed, invalidProfile
    public var errorDescription: String? {
        switch self {
        case .arcNotInstalled: "Arc isn't installed."
        case .noData: "No Arc data was found."
        case .permissionDenied: "Allow access in System Settings → Privacy & Security → Files & Folders."
        case .invalidSidebar: "Could not read Arc's sidebar. Choose StorableSidebar.json."
        case .invalidLocalState: "Arc's profile list could not be read."
        case .keychainDeclined: "Keychain access was declined."
        case .keychainUnavailable: "Arc Safe Storage could not be read from Keychain."
        case .unsupportedEncryption: "This Arc encryption version isn't supported."
        case .decryptionFailed: "An encrypted Arc value could not be decrypted."
        case .databaseFailed: "Arc's database could not be read. Try closing Arc and importing again."
        case .invalidProfile: "The Arc profile directory is invalid."
        }
    }
}
public struct ImportProgress: Sendable {
    public enum Stage: String, Sendable { case discovering, sidebar, profiles, logins, cookies, complete }
    public var stage: Stage
    public var completed: Int
    public var total: Int
}
public typealias ProgressHandler = @Sendable (ImportProgress) -> Void

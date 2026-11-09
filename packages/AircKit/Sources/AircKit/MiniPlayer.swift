// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// The same origin key is used by Settings, the engine and the Mini Player menu.
public enum MiniPlayerSite {
    public static func origin(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    public static func allowed(_ url: URL?, automatic: Bool, sites: [String: Bool]) -> Bool {
        automatic && url.flatMap { origin($0.absoluteString) }.map { sites[$0] != false } != false
    }
}

/// Collapse is idempotent: a repeated Escape must never replace the expanded frame with the pill's frame.
public struct MiniPlayerState: Equatable {
    public private(set) var expandedFrame: CGRect?
    public var isMinimized: Bool { expandedFrame != nil }
    public init() {}
    public mutating func minimize(from frame: CGRect) {
        if expandedFrame == nil { expandedFrame = frame }
    }
    public mutating func expand() -> CGRect? {
        defer { expandedFrame = nil }
        return expandedFrame
    }
}

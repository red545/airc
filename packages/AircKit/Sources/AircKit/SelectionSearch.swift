// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// A page's context menu on selected text: "Search Google for “flowers”" (C08). Chromium's menu names its own default
/// search provider, which isn't the profile's engine; both engines' menus show this item instead, searching the
/// profile's default (a site search made the default included), as Arc's menu searched the profile's engine.
public enum SelectionSearch {
    /// Chromium's kMaxSelectionTextLength.
    public static let maxShown = 50

    /// What's searched: the selection with its runs of whitespace (line breaks included) made one space, trimmed; nil
    /// when nothing is left.
    public static func query(_ selection: String) -> String? {
        let q = selection.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return q.isEmpty ? nil : q
    }

    /// Chromium's IDS_CONTENT_CONTEXT_SEARCHWEBFOR, "Search $1 for “$2”", the selection elided at a word to 50
    /// characters as Chromium's menu does.
    public static func title(_ selection: String, search: DefaultSearch) -> String? {
        guard let q = query(selection) else { return nil }
        return "Search \(search.name) for “\(elide(q))”"
    }

    /// The results page; nil for an empty selection.
    public static func url(_ selection: String, search: DefaultSearch) -> URL? {
        query(selection).flatMap(search.url(for:))
    }

    static func elide(_ q: String) -> String {
        guard q.count > maxShown else { return q }
        let cut = q.prefix(maxShown - 1)
        // At the last word break, unless that would leave almost nothing (one long word).
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxShown / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// One undo step: the blocks it changed, as they were and as they became (nil: absent), and the title.
public struct EaselEdit: Codable, Hashable, Sendable {
    public struct Change: Codable, Hashable, Sendable {
        public var id: String
        public var before: EaselBlock?
        public var after: EaselBlock?
    }

    /// What Edit › Undo says ("Undo Move").
    public var name: String
    public var changes: [Change]
    public var titleBefore: String?
    public var titleAfter: String?
    public var paletteBefore: EaselPalette?
    public var paletteAfter: EaselPalette?

    /// The difference between two documents, or nil when nothing differs. O(blocks).
    public init?(name: String, from a: EaselDocument, to b: EaselDocument) {
        self.name = name
        var old: [String: EaselBlock] = [:]
        for x in a.blocks { old[x.id] = x }
        var changes: [Change] = []
        var seen = Set<String>()
        for y in b.blocks {
            seen.insert(y.id)
            let x = old[y.id]
            if x != y { changes.append(Change(id: y.id, before: x, after: y)) }
        }
        for x in a.blocks where !seen.contains(x.id) { changes.append(Change(id: x.id, before: x, after: nil)) }
        self.changes = changes
        if a.title != b.title { titleBefore = a.title; titleAfter = b.title }
        if a.palette != b.palette { paletteBefore = a.palette; paletteAfter = b.palette }
        if changes.isEmpty && titleBefore == nil && paletteBefore == nil { return nil }
    }

    /// Undo (`forward: false`) or redo it on `d`.
    public func apply(to d: inout EaselDocument, forward: Bool) {
        var index: [String: Int] = [:]
        for (i, x) in d.blocks.enumerated() { index[x.id] = i }
        var removed = Set<String>()
        for c in changes {
            let target = forward ? c.after : c.before
            if let i = index[c.id] {
                if let t = target { d.blocks[i] = t } else { removed.insert(c.id) }
            } else if let t = target {
                index[c.id] = d.blocks.count
                d.blocks.append(t)
            }
        }
        if !removed.isEmpty { d.blocks.removeAll { removed.contains($0.id) } }
        if let t = forward ? titleAfter : titleBefore { d.title = t }
        if let p = forward ? paletteAfter : paletteBefore { d.palette = p }
    }

    /// The blocks it touches that exist after applying it that way (the editor selects them).
    public func touched(forward: Bool) -> Set<String> {
        Set(changes.filter { (forward ? $0.after : $0.before) != nil }.map(\.id))
    }
}

/// An Easel's undo and redo stacks. Saved beside the document (EaselFiles), so the last session's steps survive a
/// relaunch; `revision` names the document state the stacks end at, and stacks for another state are dropped.
public struct EaselHistory: Codable, Hashable, Sendable {
    public static let limit = 200

    public var undoStack: [EaselEdit] = []
    public var redoStack: [EaselEdit] = []
    public var revision: String = ""

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// A change from `before` to `after`, named; false when nothing changed.
    @discardableResult
    public mutating func record(_ name: String, from before: EaselDocument, to after: EaselDocument) -> Bool {
        guard let e = EaselEdit(name: name, from: before, to: after) else { return false }
        undoStack.append(e)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
        return true
    }

    /// Undoes the last step on `d`; the step, or nil when there's none.
    @discardableResult
    public mutating func undo(_ d: inout EaselDocument) -> EaselEdit? {
        guard let e = undoStack.popLast() else { return nil }
        e.apply(to: &d, forward: false)
        redoStack.append(e)
        return e
    }

    @discardableResult
    public mutating func redo(_ d: inout EaselDocument) -> EaselEdit? {
        guard let e = redoStack.popLast() else { return nil }
        e.apply(to: &d, forward: true)
        undoStack.append(e)
        return e
    }
}

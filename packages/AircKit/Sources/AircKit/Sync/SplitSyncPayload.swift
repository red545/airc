// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Pinned and Favorite splits in iCloud sync (docs/sync.md, "Splits"; P14b2). A saved split is a sidebar row like a
// folder: a `row` record of kind "split" in the sealed batch log, and each pane is a `row` record of kind "tab" whose
// parent is the split. So a split needs no record type of its own (no CloudKit schema change):
//
// - Its place (Space or Favorites, folder, order), name and icon are ordinary row fields, merged per field.
// - Its layout (axis and each pane's share, by pane record) is one `layout` field holding a `SplitSyncPayload`: last
//   writer wins per split. Which pane has the keyboard is window state and stays on each Mac.
// - Member order is each pane's own fractional order key, so two Macs reordering or adding panes at once merge pane by
//   pane instead of one list overwriting the other.
//
// Every operation on a split or on a pane goes in a batch of envelope version 3 (SyncEnvelope). Builds from before
// splits synced (before P14b2) can't open those: they keep them unread in their quarantine and apply them once updated,
// instead of making split rows they don't understand.

/// A saved split's layout as synced: inside a sealed batch, never on its own in iCloud.
public struct SplitSyncPayload: Codable, Hashable, Sendable {
    /// The format this build writes. A newer format a build can't read is ignored there: the split keeps its own
    /// layout (or the default one), never fails the batch.
    public static let currentFormat = 1
    /// More shares than this aren't valid: a split has at most `Split.maxPanes` panes, a merge may briefly see a few more.
    public static let maxShares = 16

    public var format: Int
    public var axis: SplitAxis
    /// Pane record ID (`item:<id>` or `tab:<id>`) → its share along `axis`. Read in pane order and scaled to add up to 1,
    /// as `SplitLayout.shares`; a pane without one gets an equal share.
    public var shares: [String: Double]

    public init(format: Int = Self.currentFormat, axis: SplitAxis, shares: [String: Double]) {
        self.format = format; self.axis = axis; self.shares = shares
    }

    private enum CodingKeys: String, CodingKey { case format, axis, shares }

    /// A newer format's axis this build doesn't know reads as horizontal; its shares are kept only if they read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        axis = (try? c.decode(SplitAxis.self, forKey: .axis)) ?? .horizontal
        shares = (try? c.decode([String: Double].self, forKey: .shares)) ?? [:]
    }

    /// Bounded and finite: an operation carrying anything else is refused like any malformed one.
    public var isValid: Bool {
        format >= 1 && shares.count <= Self.maxShares
            && shares.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isFinite && $0.value >= 0 && $0.value <= 1 }
    }

    /// Whether this build understands it. A newer format is ignored: the split keeps the layout it has here.
    public var isReadable: Bool { format == Self.currentFormat }

    /// The synced form of a store layout, with pane item IDs turned into their records.
    public init(_ layout: SplitLayout, panes: [String], record: (String) -> String) {
        let fractions = layout.fractions(panes)
        var shares: [String: Double] = [:]
        // Rounded so a layout read back on another Mac compares equal and is never sent back as an edit.
        for (pane, f) in zip(panes, fractions) { shares[record(pane)] = (f * 10_000).rounded() / 10_000 }
        self.init(axis: layout.axis, shares: shares)
    }

    /// The store layout on this Mac: pane records mapped to local items (`local`), focus kept from `current` if it is
    /// still a pane.
    public func layout(panes: [String], local: [String: String], current: SplitLayout?) -> SplitLayout {
        guard isReadable else { return current ?? SplitLayout() }
        var mapped: [String: Double] = [:]
        for (record, share) in shares { if let id = local[record], panes.contains(id) { mapped[id] = share } }
        let focus = current?.focusedItemID.flatMap { panes.contains($0) ? $0 : nil }
        return SplitLayout(axis: axis, shares: mapped, focusedItemID: focus)
    }
}

public enum SyncSplits {
    /// The envelope version for a batch with any split or pane operation (SyncEnvelope).
    public static let envelopeVersion = 3

    /// Whether `op` touches a saved split: the split's own record, or a pane's (its parent, in the operation or
    /// already in `replica`, is a split).
    public static func isSplitOperation(_ op: SyncOperation, in replica: SyncReplica) -> Bool {
        guard op.record.kind == .row else { return false }
        if op.fields[.layout] != nil { return true }
        if (op.fields[.kind] ?? replica.records[op.record]?[.kind]) == .text("split") { return true }
        guard case .text(let parent)? = op.fields[.parent] ?? replica.records[op.record]?[.parent] else { return false }
        return replica.records[SyncRecordID(.row, parent)]?[.kind] == .text("split")
    }
}

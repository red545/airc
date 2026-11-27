// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

// Clean-up of iCloud records nothing needs any more (syncgc, docs/sync.md "Clean-up"): a deleted note's text records,
// pictures no note uses, and an old group's records after a Start Over. Two phases everywhere: what qualifies is first
// agreed by every Mac that synced within `horizon` (their acks), then deleted only after `settle` if it still qualifies.
// Nothing is deleted while a Mac that synced within the horizon has no ack (an older build), while this Mac's own state
// isn't clean (unreadable batches, uploads waiting), or while the inventory isn't complete. Removal records (a note's
// tombstones, no text) and the current group's batches are never deleted. Public builds don't delete yet
// (`SyncGarbage.deletesEnabled`): everything else runs, and what would go is logged.
//
// No CloudKit schema change: an ack is a `SyncDevice` record named `ack.<device>` (builds from before syncgc ignore it,
// their mapping wants `device.<device>`), its `sealed` field a sealed `SyncGCAck`.

/// One record the reads have seen: its type and group (the `group` field), for the clean-up inventory.
public struct SyncInventoryEntry: Codable, Hashable, Sendable {
    public var type: String
    public var group: String?
    public init(type: String, group: String?) { self.type = type; self.group = group }
}

/// What one Mac tells the others about clean-up, sealed in its ack record.
public struct SyncGCAck: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        /// Every version of the note this Mac has seen (its `known` vector), when it has the note removed.
        public var vector: SyncNoteVector
        /// When this Mac deleted its own text record of it (kept a while, so slower Macs still see the agreement).
        public var collected: Date?
        public init(vector: SyncNoteVector, collected: Date? = nil) { self.vector = vector; self.collected = collected }
    }

    /// A collector's picture proposal: pictures it found no note uses. Each Mac answers with `seen` and `keep`.
    public struct Proposal: Codable, Equatable, Sendable {
        public var epoch: Int
        public var at: Date
        public var assets: [String]
        public init(epoch: Int, at: Date, assets: [String]) { self.epoch = epoch; self.at = at; self.assets = assets }
    }

    public static let format = 1
    public var format = Self.format
    /// Notes this Mac has removed: not pinned here, nothing of them waiting to go up.
    public var notes: [String: Note] = [:]
    /// Per collector (device UUID string): the proposal epoch this Mac has read.
    public var seen: [String: Int] = [:]
    /// The proposed pictures (asset record names) this Mac still uses.
    public var keep: [String] = []
    /// This Mac's own proposal, when it's the collector.
    public var proposal: Proposal?
    /// Pictures this Mac deleted (asset record names) and when: a Mac that still uses one uploads it again.
    public var gone: [String: Date] = [:]

    public init() {}

    private static func authentication(_ group: UUID, _ device: UUID) -> Data {
        Data("Airc-sync-ack|\(group.uuidString)|\(device.uuidString)".utf8)
    }

    public func seal(group: UUID, device: UUID, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let sealed = try AES.GCM.seal(encoder.encode(self), using: key, authenticating: Self.authentication(group, device)).combined
        else { throw SyncError.invalidEnvelope }
        return sealed
    }

    /// nil: not this group's, damaged, or a newer format (then its Mac counts as not having acked: nothing is deleted).
    public static func open(_ record: SyncDeviceRecord, group: UUID, key: SymmetricKey) -> SyncGCAck? {
        guard record.group == group, let box = try? AES.GCM.SealedBox(combined: record.sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: authentication(group, record.device)),
              let ack = try? JSONDecoder().decode(SyncGCAck.self, from: plain), ack.format == format else { return nil }
        return ack
    }
}

/// What clean-up would have deleted while deletes are off (`SyncGarbage.deletesEnabled`): counts and record types only,
/// never names or content. In the sync log and Settings › Sync's diagnostics.
public struct SyncGCDryRun: Codable, Equatable, Sendable {
    /// When the plan was checked (each record fetched and checked again, as before a real delete).
    public var at: Date
    /// Records that would be deleted.
    public var records: Int
    /// Per CloudKit record type (SyncNote, SyncNoteAsset, …).
    public var types: [String: Int]
    /// Per kind: `noteText` (deleted notes' texts), `asset` (unused pictures), `oldGroup` (an old group's records).
    public var kinds: [String: Int]

    public init(at: Date, records: Int, types: [String: Int], kinds: [String: Int]) {
        self.at = at; self.records = records; self.types = types; self.kinds = kinds
    }

    /// "2 deleted notes' texts, 1 unused picture" (nothing: "nothing").
    public var what: String {
        let parts: [(String, String, String)] = [("noteText", "deleted note's text", "deleted notes' texts"),
                                                 ("asset", "unused picture", "unused pictures"),
                                                 ("oldGroup", "record of an old group", "records of an old group")]
        let said = parts.compactMap { key, one, many in kinds[key].flatMap { $0 > 0 ? "\($0) " + ($0 == 1 ? one : many) : nil } }
        return said.isEmpty ? "nothing" : said.joined(separator: ", ")
    }

    /// The sync log's line.
    public var logLine: String {
        let byType = types.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return "clean-up dry run (deletes are off in this build): would delete \(records) record(s)"
            + (byType.isEmpty ? "" : ": " + byType) + " (" + what + ")"
    }
}

public enum SyncGarbage {
    /// Whether clean-up really deletes records from iCloud. Off in public builds until the real-iCloud proof (parity
    /// audit Y01 with a delete pass in a test zone): acks, proposals and bookkeeping still run, and each plan is checked
    /// as before a delete, but nothing is deleted; what would go is logged (`SyncGCDryRun`). On in test builds, so the
    /// scripted checks keep proving the delete path. The engine reads it through `Environment.gcDeletes`.
    #if AIRC_TESTING
    public static let deletesEnabled = true
    #else
    public static let deletesEnabled = false
    #endif
    /// A Mac that hasn't synced for this long stops holding clean-up back (docs/sync.md "Clean-up"; ASK: 30 days).
    public static let horizon: TimeInterval = 30 * 86400
    /// Everything that qualifies waits this long, then is checked again before it's deleted.
    public static let settle: TimeInterval = 86400
    /// A collected note stays in its Mac's ack this long.
    public static let collectedRetention: TimeInterval = 90 * 86400
    /// Deleted pictures stay announced this long, and at most this many.
    public static let goneRetention: TimeInterval = 365 * 86400
    public static let goneLimit = 2000

    /// Who may delete what another Mac wrote: the lowest device ID among the Macs that count (all of which have acks).
    static func collector(_ live: Set<UUID>) -> UUID? { live.min { $0.uuidString < $1.uuidString } }

    /// Record types whose names a Mac overwrites (checked again just before a delete); the others are create-only.
    static func isMutable(_ name: String) -> Bool {
        name.hasPrefix("note.") || name.hasPrefix("device.") || name.hasPrefix("ack.")
    }
}

/// The Macs that count for clean-up, from device records and acks of this group.
struct SyncGCView {
    var me: UUID
    var group: UUID
    var now: Date
    var horizon: TimeInterval
    /// Readable acks of this group's other Macs.
    var acks: [UUID: SyncGCAck]
    /// Macs that synced within the horizon (this one always).
    var live: Set<UUID>
    /// A Mac that counts has no readable ack (an older build, a newer format): nothing is deleted.
    var blocked: Bool

    init(me: UUID, group: UUID, now: Date, horizon: TimeInterval, devices: [SyncDeviceRecord], acks: [SyncDeviceRecord],
         key: SymmetricKey) {
        self.me = me; self.group = group; self.now = now; self.horizon = horizon
        var opened: [UUID: SyncGCAck] = [:]
        var lastSeen: [UUID: Date] = [:]
        for d in devices where d.group == group { lastSeen[d.device] = max(lastSeen[d.device] ?? .distantPast, d.seen) }
        for a in acks where a.group == group {
            lastSeen[a.device] = max(lastSeen[a.device] ?? .distantPast, a.seen)
            if a.device != me, let ack = SyncGCAck.open(a, group: group, key: key) { opened[a.device] = ack }
        }
        var live: Set<UUID> = [me]
        for (device, seen) in lastSeen where now.timeIntervalSince(seen) <= horizon { live.insert(device) }
        self.acks = opened
        self.live = live
        blocked = live.contains { $0 != me && opened[$0] == nil }
    }

    var collector: UUID? { blocked ? nil : SyncGarbage.collector(live) }
    var isCollector: Bool { collector == me }

    /// Every other Mac that counts has note `id` removed, having seen exactly `vector`.
    func agree(note id: String, vector: SyncNoteVector) -> Bool {
        !blocked && live.allSatisfy { $0 == me || acks[$0]?.notes[id]?.vector == vector }
    }
}

/// Clean-up bookkeeping, in the engine's state file.
struct SyncGCState: Codable, Equatable {
    struct Doomed: Codable, Equatable {
        enum Kind: String, Codable { case noteText, asset, oldGroup }
        var name: String
        var kind: Kind
        /// noteText: the vector that must dominate the record's version; oldGroup: the group the record must still be in.
        var vector: SyncNoteVector?
        var group: String?
    }

    /// The ack content last published (nil: none yet, publish one).
    var ack: SyncGCAck?
    /// When each removed note was first agreed on, own text record deleted, other gone Macs' records deleted.
    var agreed: [String: Date] = [:]
    var collected: [String: Date] = [:]
    var swept: [String: Date] = [:]
    /// Pictures of any group and every record of another group, by name (from the reads).
    var inventory: [String: SyncInventoryEntry] = [:]
    var inventoryComplete = false
    /// Old groups found collectable, and since when.
    var oldGroups: [String: Date] = [:]
    /// This Mac's picture proposal as the collector, its last epoch, and the pictures it deleted.
    var proposal: SyncGCAck.Proposal?
    var epoch = 0
    var gone: [String: Date] = [:]
    /// Per other Mac: the latest `gone` date this Mac has acted on.
    var goneRead: [String: Date] = [:]
    /// Deletes decided but not finished (a quit or crash): checked again and finished by the next cycle.
    var plan: [Doomed] = []
    /// Notes the plan collects (own records) or sweeps (gone Macs' records).
    var planCollects: [String] = []
    var planSweeps: [String] = []
    var planProposal: Int?
    /// Proposed pictures a Mac kept (a Today note uses them): not proposed again until the horizon has passed.
    var held: [String: Date] = [:]
    /// Deletes off (`SyncGarbage.deletesEnabled`): the last dry run, and the plan it checked (the same plan isn't
    /// checked and logged again until the settle delay has passed).
    var dryRun: SyncGCDryRun?
    var dryRunPlan: [Doomed] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case ack, agreed, collected, swept, inventory, inventoryComplete, oldGroups, proposal, epoch, gone, goneRead, plan
        case planCollects, planSweeps, planProposal, held, dryRun, dryRunPlan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ack = try c.decodeIfPresent(SyncGCAck.self, forKey: .ack)
        agreed = try c.decodeIfPresent([String: Date].self, forKey: .agreed) ?? [:]
        collected = try c.decodeIfPresent([String: Date].self, forKey: .collected) ?? [:]
        swept = try c.decodeIfPresent([String: Date].self, forKey: .swept) ?? [:]
        inventory = try c.decodeIfPresent([String: SyncInventoryEntry].self, forKey: .inventory) ?? [:]
        inventoryComplete = try c.decodeIfPresent(Bool.self, forKey: .inventoryComplete) ?? false
        oldGroups = try c.decodeIfPresent([String: Date].self, forKey: .oldGroups) ?? [:]
        proposal = try c.decodeIfPresent(SyncGCAck.Proposal.self, forKey: .proposal)
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        gone = try c.decodeIfPresent([String: Date].self, forKey: .gone) ?? [:]
        goneRead = try c.decodeIfPresent([String: Date].self, forKey: .goneRead) ?? [:]
        plan = try c.decodeIfPresent([Doomed].self, forKey: .plan) ?? []
        planCollects = try c.decodeIfPresent([String].self, forKey: .planCollects) ?? []
        planSweeps = try c.decodeIfPresent([String].self, forKey: .planSweeps) ?? []
        planProposal = try c.decodeIfPresent(Int.self, forKey: .planProposal)
        held = try c.decodeIfPresent([String: Date].self, forKey: .held) ?? [:]
        dryRun = try c.decodeIfPresent(SyncGCDryRun.self, forKey: .dryRun)
        dryRunPlan = try c.decodeIfPresent([Doomed].self, forKey: .dryRunPlan) ?? []
    }

    /// A read's records into the inventory: pictures of any group and anything of another group are kept; this group's
    /// other records aren't needed. A full read replaces it and makes it complete.
    mutating func take(_ report: SyncReadReport, group: UUID) {
        if report.full { inventory = [:]; inventoryComplete = true }
        for (name, entry) in report.records {
            let keep = entry.type == SyncCloudSchema.noteAsset || (entry.group != nil && entry.group != group.uuidString)
            // Never the group record: it names the current group, and there is only one.
            inventory[name] = keep && entry.type != SyncCloudSchema.group ? entry : nil
        }
        for name in report.deleted { inventory[name] = nil }
    }

    /// Pictures deleted more than a year ago, or past the newest 2000, aren't announced any more.
    mutating func pruneGone(now: Date) {
        gone = gone.filter { now.timeIntervalSince($0.value) <= SyncGarbage.goneRetention }
        if gone.count > SyncGarbage.goneLimit {
            let keep = gone.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(SyncGarbage.goneLimit)
            gone = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

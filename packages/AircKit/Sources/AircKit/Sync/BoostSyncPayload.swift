// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

// Boosts and archive timing in iCloud sync (docs/sync.md, "Boosts" and "Archive timing"), P14b3. No record type of their
// own (no CloudKit schema change): like settings, each site's Boost is one `boost` record in the same sealed batch log,
// whose one field, `value`, holds a `BoostSyncPayload`.
//
// - Last writer wins per site: the later change on its Mac, then the later stamp (SyncRegister.precedes). A deletion is
//   a change too, so it reaches every Mac, and an older copy never brings the Boost back.
// - Style travels as it is: colours, font, size, zaps, CSS, name, on or off.
// - JavaScript never runs on a Mac just because it synced. It arrives held (`Boost.heldCode`) and runs only after the
//   person allows it on that Mac. The payload says which Mac the person allowed it on (`allowedOn`), so the next Mac
//   asks with a one-click confirm that names it ("You allowed this code on <Mac>"); code no Mac vouched for gets the
//   full review. Code that is already allowed on a Mac, byte for byte and for the same host, keeps running there.
// - A Boost held for its site (`Boost.needsSite`) stays on its Mac.
//
// Archive timing: a Today tab's archive timer runs from its last use. When a pinned tab leaves Pinned on one Mac (its
// page goes to Today there), that Mac also sends when the tab was last used there (`SyncField.used`), and a Mac that
// keeps the page as a Today tab continues its timer from the later of the two uses instead of its own. Only then: the
// time of every use would turn the log into a browsing record.
//
// Both go in batches of envelope version 5 (SyncEnvelope), never with sidebar operations: builds from before Boosts
// synced can't open those and keep them unread in their quarantine, as with notes, splits and settings.

/// One site's Boost as synced: inside a sealed batch, never on its own in iCloud. Dates are whole seconds (as Boosts.json
/// keeps them), so a Boost that came from another Mac gives the same payload after a relaunch.
public struct BoostSyncPayload: Codable, Hashable, Sendable {
    /// The format this build writes. A newer one is ignored here: the site keeps the Boost it has on this Mac.
    public static let currentFormat = 1
    /// A larger Boost stays on its Mac (a Boost file may be 256 KB). Below a batch's 512 KB.
    public static let maxBytes = 256 * 1024

    public var format: Int
    /// Deleted on its Mac at `changed`: every other field is empty.
    public var removed: Bool
    /// When it was changed (or deleted) on its Mac, in milliseconds since 1970 (whole seconds).
    public var changed: Int64
    public var created: Int64
    public var name: String?
    public var enabled: Bool
    public var colors: BoostColors
    public var font: BoostFont
    public var zaps: [BoostZap]
    public var css: String
    /// The JavaScript: what runs on the sending Mac, or what waits there (`heldCode`), so it reaches every Mac.
    public var js: String
    public var scriptHost: String?
    public var origin: BoostOrigin?
    /// The Mac the person allowed `js` on, as it names itself; nil without code, or when no Mac vouched for it. Not part
    /// of what counts as a change (`content`): it only words the confirm.
    public var allowedOn: String?

    public init(format: Int = Self.currentFormat, removed: Bool = false, changed: Int64, created: Int64 = 0, name: String? = nil,
                enabled: Bool = true, colors: BoostColors = BoostColors(), font: BoostFont = BoostFont(), zaps: [BoostZap] = [],
                css: String = "", js: String = "", scriptHost: String? = nil, origin: BoostOrigin? = nil, allowedOn: String? = nil) {
        self.format = format; self.removed = removed; self.changed = changed; self.created = created; self.name = name
        self.enabled = enabled; self.colors = colors; self.font = font; self.zaps = zaps; self.css = css; self.js = js
        self.scriptHost = scriptHost; self.origin = origin; self.allowedOn = allowedOn
    }

    /// This Mac's Boost as it syncs. `thisMac`: the name this Mac's allowed code is vouched for with. This Mac vouches
    /// for code it runs, or would run when switched on, that the person wrote here (or allowed from another Mac); code
    /// installed from someone else's file vouches only once switched on (BST-2 installs it off). Held code passes on the
    /// Mac that vouched for it.
    public init(_ b: Boost, thisMac: String) {
        let code = b.heldCode.map { ($0.js, $0.scriptHost) } ?? (b.js, b.scriptHost)
        let hasCode = !code.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let vouch: String? = !hasCode ? nil
            : b.heldCode != nil ? b.heldCode?.allowedOn
            : b.enabled || b.origin?.kind != .installed ? thisMac : nil
        self.init(changed: Self.millis(b.modified), created: Self.millis(b.created), name: b.name, enabled: b.enabled,
                  colors: b.colors, font: b.font, zaps: b.zaps.map(Self.wholeSeconds), css: b.css,
                  js: hasCode ? code.0 : "", scriptHost: hasCode ? code.1 : nil, origin: b.origin.map(Self.wholeSeconds),
                  allowedOn: vouch)
    }

    /// A deletion at `date`.
    public static func removal(at date: Date) -> Self { Self(removed: true, changed: millis(date), enabled: false) }

    public var isValid: Bool {
        guard format >= 1, changed >= 0, created >= 0, (name?.utf8.count ?? 0) <= 2048, (allowedOn?.utf8.count ?? 0) <= 512
        else { return false }
        if removed { return js.isEmpty && css.isEmpty && zaps.isEmpty }
        guard zaps.count <= 2000, zaps.allSatisfy({ BoostZap.isValidSelector($0.selector) }),
              let data = try? JSONEncoder().encode(self) else { return false }
        return data.count <= Self.maxBytes
    }

    public var isReadable: Bool { format == Self.currentFormat }

    public var hasCode: Bool { !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What counts as a change: everything but `allowedOn`, as a short digest (the engine's baseline).
    public var content: String {
        var c = self
        c.allowedOn = nil
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = (try? e.encode(c)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The Boost this Mac keeps for `domain`, given the one it has (`existing`). Style is taken as it is. The code runs
    /// here only if this Mac already runs exactly this code for the same host; otherwise it waits in `heldCode` (the
    /// same held code stays held, with the Mac that vouched for it first), and any other code that ran here stops.
    public func boost(domain: String, existing: Boost?) -> Boost {
        var b = Boost(domain: domain, enabled: enabled, colors: colors, font: font, zaps: zaps, css: css,
                      origin: origin, created: Self.date(created), modified: Self.date(changed))
        b.name = name
        guard hasCode else { return b }
        // Hosts compared as this Mac keys them: a site that is one exact host has none.
        let exact = BoostDomain.isExactHost(domain)
        let host = exact ? nil : scriptHost
        if let e = existing, e.heldCode == nil, !e.needsSite, e.js == js, (exact ? nil : e.scriptHost) == host {
            b.js = js; b.scriptHost = host
        } else if let h = existing?.heldCode, h.js == js, (exact ? nil : h.scriptHost) == host {
            b.heldCode = h
        } else {
            b.heldCode = BoostHeldCode(js: js, scriptHost: host, allowedOn: allowedOn)
        }
        return b
    }

    static func millis(_ date: Date) -> Int64 { Int64(max(0, date.timeIntervalSince1970.rounded(.down))) * 1000 }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis / 1000)) }
    static func wholeSeconds(_ z: BoostZap) -> BoostZap { var z = z; z.created = date(millis(z.created)); return z }
    static func wholeSeconds(_ o: BoostOrigin) -> BoostOrigin { var o = o; o.date = date(millis(o.date)); return o }
}

/// The app's Boosts, as the engine sees them.
public struct SyncBoostsSource {
    /// Every Boost (and deletion) this Mac would sync, by site, given this Mac's name for `allowedOn`.
    public var current: (_ thisMac: String) -> [String: BoostSyncPayload]
    /// Boosts and deletions from other Macs. Returns the sites it applied; one it can't apply now is tried again.
    public var apply: ([String: BoostSyncPayload]) -> Set<String>

    public init(current: @escaping (String) -> [String: BoostSyncPayload], apply: @escaping ([String: BoostSyncPayload]) -> Set<String>) {
        self.current = current; self.apply = apply
    }
}

public enum SyncBoosts {
    /// The envelope version for a batch of Boosts or of archive timing (SyncEnvelope).
    public static let envelopeVersion = 5

    /// A site as a record ID: lowercase ASCII host characters, as BoostDomain makes them.
    public static func isValidSite(_ site: String) -> Bool {
        !site.isEmpty && site.utf8.count <= 253
            && site.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || ".-:".unicodeScalars.contains($0)) }
    }

    /// Boosts as this Mac would sync them: never one held for its site.
    public static func payloads(_ store: BoostStore, thisMac: String) -> [String: BoostSyncPayload] {
        var result: [String: BoostSyncPayload] = [:]
        for (site, date) in store.removed where isValidSite(site) { result[site] = .removal(at: date) }
        for b in store.boosts.values where !b.needsSite && isValidSite(b.domain) {
            let p = BoostSyncPayload(b, thisMac: thisMac)
            if p.isValid { result[b.domain] = p }
        }
        return result
    }

    /// Applies other Macs' Boosts to `store`. Returns the sites applied (all of them: a Boost held for its site here is
    /// left alone, as a local choice).
    @discardableResult
    public static func apply(_ incoming: [String: BoostSyncPayload], to store: BoostStore) -> Set<String> {
        var done = Set<String>()
        for (site, p) in incoming.sorted(by: { $0.key < $1.key }) where isValidSite(site) && p.isReadable {
            if store.boost(domain: site)?.needsSite == true { done.insert(site); continue }
            if p.removed { store.removeSynced(domain: site, at: BoostSyncPayload.date(p.changed)) }
            else { store.applySynced(p.boost(domain: site, existing: store.boost(domain: site))) }
            done.insert(site)
        }
        return done
    }
}

/// What the engine keeps per Mac about Boosts (in its state file).
struct SyncBoostsState: Codable, Equatable {
    /// "Sync Boosts" is off on this Mac (Settings › Sync): nothing is sent or applied; on by default with sync.
    var off = false
    /// Site → the content (`BoostSyncPayload.content`) this Mac last sent or applied.
    var baseline: [String: String] = [:]
}

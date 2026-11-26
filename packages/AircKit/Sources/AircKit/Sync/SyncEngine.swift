// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// What the first sync on a Mac that finds a sidebar in iCloud shows before it changes anything.
public struct SyncFirstSync: Equatable, Sendable {
    public struct Side: Equatable, Sendable {
        public var spaces: [String]
        public var pinned: Int
        public var favorites: Int
    }

    /// A profile the iCloud sidebar uses that this Mac doesn't have.
    public struct Profile: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var emoji: String
        /// Names of the iCloud Spaces that use it.
        public var spaces: [String]
        /// A profile here with the same name, offered first (never used without the person choosing it).
        public var suggestion: String?
    }

    public var thisMac: Side
    public var iCloud: Side
    public var profiles: [Profile]
    /// Every batch in iCloud could be read. When some can't (damaged, or from a newer Airc), Replace isn't offered:
    /// it would replace this Mac's sidebar with part of iCloud's.
    public var complete = true
    /// The local profile the group's default profile maps to (already taken: choosing it for another profile too
    /// puts both profiles' Spaces in it).
    public var defaultProfile: String?
}

public enum SyncFirstSyncChoice: Sendable { case merge, replace }

/// For each iCloud profile this Mac lacks: a new empty profile (no logins), or one of this Mac's.
public enum SyncProfileChoice: Hashable, Sendable { case create, use(String) }

/// Sidebar sync between Macs: captures the store's changes after each action, seals them with the group key, sends
/// them through a `SyncGroupTransport` (CloudKit in release builds) and applies what other Macs sent. Main actor:
/// it reads and writes the store the UI uses.
///
/// First Mac: no group in iCloud → it makes the group key, saves it to iCloud Keychain, creates the group record and
/// uploads its sidebar. Second Mac: finds the group record, waits for the key to arrive through iCloud Keychain
/// (`waitingForKeychain`), reads everything and asks: merge, or replace this Mac's sidebar (a backup first).
///
/// Safety rules (syncspike's design plus the 2026-11-07 review):
/// - A read is acknowledged only after what it brought is merged, applied and saved; nothing is checkpointed past a
///   record CloudKit couldn't return or a batch that couldn't be read (that one is kept, retried and reported).
/// - Applying remote changes is journaled: the replica is saved first with `applyMode` set, so a quit or crash between
///   the store's commit and the next save re-applies (idempotent: remote records have stable local IDs) instead of
///   taking the store's changes for this Mac's own.
/// - Every save throws; a failed save stops the cycle before anything is uploaded or acknowledged.
/// - Any zone the server lost (recreated by any request, or a full read missing batches this Mac uploaded) sets
///   `recovery` until the group record is back and verified and this Mac's whole history is uploaded again.
/// - Every suspension point is followed by a session check: switching sync off, an account change or Cancel ends
///   in-flight work before its next request. The first-sync choice is bound to the account it was offered for.
/// - No transport (no CloudKit objects) exists while sync is off.
@MainActor
public final class SyncEngine {
    public enum Status: Equatable, Sendable {
        case off
        /// Not possible right now (not signed in to iCloud, no entitlement); the message says why.
        case unavailable(String)
        case connecting
        case waitingForKeychain
        case choosing(SyncFirstSync)
        case syncing
        case upToDate
        /// Synced, except batches that can't be read here (damaged, or from a newer Airc); they're kept and retried.
        case incomplete(String)
        /// Something failed; it tries again by itself.
        case retrying(String)
        /// It stopped and turned itself off (data deleted in iCloud, another account): the switch starts over.
        case stopped(String)
    }

    public struct Device: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var seen: Date
        public var isThisMac: Bool
    }

    public struct Environment {
        /// Builds the transport for this installation's device ID. Called only while sync is on.
        public var transport: (UUID) -> SyncGroupTransport
        public var keys: SyncKeyStore
        /// The engine's own file: replica, adapter, outbox, checkpoint. Never the key.
        public var stateURL: URL
        public var deviceName: String
        /// Identifies the hardware: a copied data folder on another Mac gets a new device ID.
        public var machine: String?
        public var now: () -> Date = Date.init
        /// A new empty local profile; returns its ID.
        public var createProfile: (_ name: String, _ emoji: String) throws -> String
        /// Moves a Space and its open pages to another profile (SpacesStore.setProfile plus the engine's reload).
        public var applyProfileChange: (_ space: String, _ profile: String) -> Void
        /// A backup of this Mac's sidebar before the first sync changes it; returns the file.
        public var backup: () throws -> URL
        public var sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }   // await-ok: a clock
        /// Where note pictures are (the data folder's Notes/Images). nil: notes sync without their pictures.
        public var notePictures: SyncNotePictureFolder?
        /// Pictures that arrived from another Mac (the app redraws open notes).
        public var picturesArrived: (([String]) -> Void)?
        /// The app's settings (SettingSyncPayload.swift). nil: settings don't sync.
        public var settings: SyncSettingsSource?
        /// The app's Boosts (BoostSyncPayload.swift). nil: Boosts don't sync.
        public var boosts: SyncBoostsSource?

        public init(transport: @escaping (UUID) -> SyncGroupTransport, keys: SyncKeyStore, stateURL: URL, deviceName: String,
                    machine: String? = nil, createProfile: @escaping (String, String) throws -> String,
                    applyProfileChange: @escaping (String, String) -> Void, backup: @escaping () throws -> URL) {
            self.transport = transport; self.keys = keys; self.stateURL = stateURL; self.deviceName = deviceName
            self.machine = machine; self.createProfile = createProfile; self.applyProfileChange = applyProfileChange
            self.backup = backup
        }
    }

    enum ApplyMode: String, Codable { case merge, replace }

    struct State: Codable {
        var version = 1
        var enabled = false
        var device = UUID()
        var machine: String?
        var group: UUID?
        /// The first sync on this Mac happened (merged, replaced, or it was the first Mac).
        var joined = false
        var replica: SyncReplica
        var adapter = SyncStoreAdapter()
        /// Sealed batches waiting for upload, in order. Survives a quit.
        var outbox: [SyncEnvelope] = []
        var checkpoint: Data?
        var account: String?
        var lastSynced: Date?
        var published: Date?
        /// This Mac's batches believed to be on the server; a full read missing any of them means a reset.
        var uploaded: Set<UUID> = []
        /// The server lost the zone: until the group record and this Mac's whole history are back.
        var recovery = false
        /// The replica holds remote changes the store may not show yet: apply them (again) before capturing.
        var applyMode: ApplyMode?
        /// Batches that couldn't be read (kept to retry, for example after an update), and unparseable record names.
        var quarantine: [SyncEnvelope] = []
        var malformed: Set<String> = []
        /// Notes: what this Mac knows, shows and owes of each (NoteSyncPayload.swift).
        var notes = SyncNoteState()
        /// Settings: the switch, and what this Mac last sent or applied (SettingSyncPayload.swift).
        var settings = SyncSettingsState()
        /// Boosts: the switch, and what this Mac last sent or applied (BoostSyncPayload.swift).
        var boosts = SyncBoostsState()

        init(device: UUID = UUID(), machine: String?) {
            self.device = device; self.machine = machine
            replica = SyncReplica(device: device)
        }

        private enum CodingKeys: String, CodingKey {
            case version, enabled, device, machine, group, joined, replica, adapter, outbox, checkpoint, account, lastSynced
            case published, uploaded, recovery, applyMode, quarantine, malformed, notes, settings, boosts
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            device = try c.decode(UUID.self, forKey: .device)
            machine = try c.decodeIfPresent(String.self, forKey: .machine)
            group = try c.decodeIfPresent(UUID.self, forKey: .group)
            joined = try c.decode(Bool.self, forKey: .joined)
            replica = try c.decode(SyncReplica.self, forKey: .replica)
            adapter = try c.decode(SyncStoreAdapter.self, forKey: .adapter)
            outbox = try c.decode([SyncEnvelope].self, forKey: .outbox)
            checkpoint = try c.decodeIfPresent(Data.self, forKey: .checkpoint)
            account = try c.decodeIfPresent(String.self, forKey: .account)
            lastSynced = try c.decodeIfPresent(Date.self, forKey: .lastSynced)
            published = try c.decodeIfPresent(Date.self, forKey: .published)
            uploaded = try c.decodeIfPresent(Set<UUID>.self, forKey: .uploaded) ?? []
            recovery = try c.decodeIfPresent(Bool.self, forKey: .recovery) ?? false
            applyMode = try c.decodeIfPresent(ApplyMode.self, forKey: .applyMode)
            quarantine = try c.decodeIfPresent([SyncEnvelope].self, forKey: .quarantine) ?? []
            malformed = try c.decodeIfPresent(Set<String>.self, forKey: .malformed) ?? []
            // A state file from before notes synced: the next capture sends this Mac's pinned notes.
            notes = try c.decodeIfPresent(SyncNoteState.self, forKey: .notes) ?? SyncNoteState()
            // A state file from before settings synced: on, nothing sent yet (the next capture sends what was changed).
            settings = try c.decodeIfPresent(SyncSettingsState.self, forKey: .settings) ?? SyncSettingsState()
            // From before Boosts synced: on, nothing sent yet (the next capture sends this Mac's Boosts).
            boosts = try c.decodeIfPresent(SyncBoostsState.self, forKey: .boosts) ?? SyncBoostsState()
        }
    }

    /// A batch's sealed payload (the operations' JSON array plus AES-GCM's nonce and tag) is at most this many bytes: far
    /// below CloudKit's 1 MB record limit. The adapter caps each value (`SyncStoreAdapter.maxURLBytes`, `maxTextBytes`),
    /// so one operation always fits.
    public static let maxBatchBytes = 512 * 1024
    public static let maxBatchOperations = 500
    /// Each cycle retries at most this much of the quarantine (oldest first, then round-robin), so a growing quarantine
    /// can't make every cycle slower without bound.
    public static let quarantineRetryCount = 32
    public static let quarantineRetryBytes = 1024 * 1024
    /// Seconds after typing in a note stops before its text is sent.
    public static let noteDebounce: Double = 3

    private struct Joining {
        var group: SyncGroupRecord
        var key: SymmetricKey
        var remote: SyncReplica
        var quarantine: [SyncEnvelope]
        var malformed: Set<String>
        /// The Apple Account the choice was offered for, and the session it belongs to.
        var account: String?
        var generation: Int
    }

    public let store: SpacesStore
    private let env: Environment
    private var state: State
    private var transport: SyncGroupTransport?
    private var key: SymmetricKey?
    private var pending: Joining?
    /// The session whose cycle loop runs, in `loopTask`. A new session starts its own loop at once; an obsolete one
    /// (cancelled, maybe still inside a retry sleep that ignores cancellation) ends by itself and changes nothing.
    private var loopGeneration: Int?
    private var loopTask: Task<Void, Never>?
    private var rerun = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var applying = false
    private var observer: Int?
    private var scheduled: Task<Void, Never>?
    private var failures = 0
    /// A new session on every switch on or off, Cancel, account change and stop: work from an older one ends at its
    /// next check, and its transport is cancelled so no request of it starts.
    private var generation = 0
    /// A save failed: the state on disk is behind memory. Nothing is uploaded until a save succeeds again.
    private var unsaved = false
    /// How many quarantined batches the last cycle retried (tests).
    public private(set) var lastQuarantineRetries = 0

    public private(set) var status: Status = .off { didSet { if status != oldValue { onChange?() } } }
    public private(set) var devices: [Device] = [] { didSet { if devices != oldValue { onChange?() } } }
    public var onChange: (() -> Void)?
    /// Off in unit tests: only `syncNow()` runs a cycle, and nothing is scheduled.
    public var automatic = true
    /// Seconds after a store change before it's sent (several quick edits go in one batch).
    public var debounce: Double = 1.5

    public var isEnabled: Bool { state.enabled }
    public var lastSynced: Date? { state.lastSynced }
    public var groupID: UUID? { state.group }
    public var deviceID: UUID { state.device }
    public var hasJoined: Bool { state.joined }
    public var pendingUploads: Int { state.outbox.count }
    public var replica: SyncReplica { state.replica }
    /// Whether a transport (with its CloudKit objects) exists: only while sync is on.
    public var hasTransport: Bool { transport != nil }
    public var unreadableBatches: Int { state.quarantine.count + state.malformed.count + state.notes.unreadable.count }
    /// Pinned notes whose text is too large to sync (SyncNotes.maxNoteBytes): their rows sync, their text doesn't.
    public var notesTooLarge: Int { state.notes.tooLarge.count }
    /// iCloud refused notes in the last cycle (their record types aren't deployed in this container yet, docs/sync.md
    /// "Deploying the schema"): they wait, and everything else syncs.
    public private(set) var notesHeld = false { didSet { if notesHeld != oldValue { onChange?() } } }
    private var holdingNotes = false
    /// Notes this Mac syncs (pinned here, or known from another Mac and not removed).
    public var syncedNotes: Int { state.notes.entries.values.filter { !$0.removed }.count }
    public var needsRecovery: Bool { state.recovery }
    /// Settings › Sync › "Sync settings": on by default while sync is on.
    public var syncsSettings: Bool { !state.settings.off }

    /// The "Sync settings" switch. Turning it on sends what changed here meanwhile and takes what changed elsewhere, by
    /// the same rule (the later change wins); off sends and applies nothing.
    public func setSyncsSettings(_ on: Bool) {
        guard on == state.settings.off else { return }
        state.settings.off = !on
        trySave()
        onChange?()
        if on { syncSoon() }
    }

    /// A setting changed (the app's settings, not the store): send it shortly, as a store change.
    public func settingsChanged() { if state.enabled && !state.settings.off { localChanged() } }

    /// Settings › Sync › "Sync Boosts": on by default while sync is on.
    public var syncsBoosts: Bool { !state.boosts.off }

    /// The "Sync Boosts" switch. On sends this Mac's Boosts changed meanwhile and takes the others' (the later change
    /// wins); off sends and applies nothing. Code from another Mac still waits for the person either way.
    public func setSyncsBoosts(_ on: Bool) {
        guard on == state.boosts.off else { return }
        state.boosts.off = !on
        trySave()
        onChange?()
        if on { syncSoon() }
    }

    /// A Boost changed (the app's Boosts, not the store): send it shortly, as a store change.
    public func boostsChanged() { if state.enabled && !state.boosts.off { localChanged() } }

    public init(store: SpacesStore, environment: Environment) {
        self.store = store
        env = environment
        var loaded = (try? Data(contentsOf: environment.stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State(machine: environment.machine)
        if let machine = environment.machine, loaded.machine != machine {
            // A copied data folder (Migration Assistant, a restored backup): same history, a device ID of its own.
            var replica = SyncReplica()
            try? replica.receive(loaded.replica.log, now: 0)
            loaded.device = replica.clock.device
            loaded.replica = replica
            loaded.machine = machine
            loaded.checkpoint = nil
            loaded.outbox = []
            loaded.uploaded = []
            loaded.notes.outbox = [:]
            loaded.notes.picturesUp = []
            loaded.notes.pictureOutbox = []
        }
        state = loaded
        observer = store.observe { [weak self] change in
            guard let self, !self.applying else { return }
            if change.contentOnly {
                // Typing in a note (its text or title): sent a little after the typing stops. Other content-only changes
                // (page titles, favicons) don't sync.
                if change.touches(.note) { self.localChanged(after: Self.noteDebounce) }
                return
            }
            self.localChanged()
        }
        if state.enabled { status = .connecting }
    }

    /// The Settings switch. Off keeps the group, the key and what was synced, so on picks up where it left. Off also
    /// ends any work in flight and drops the transport.
    public func setEnabled(_ on: Bool) {
        guard on != state.enabled else { return }
        state.enabled = on
        generation += 1
        trySave()
        if on {
            status = .connecting
            if automatic { Task { await run() } }   // await-ok: run() takes the session current when it starts
        } else {
            endSession()
            status = .off
        }
    }

    /// Activation, a push, the fallback timer, Sync Now.
    public func syncSoon() {
        guard state.enabled, automatic else { return }
        Task { await run() }   // await-ok: run() takes the session current when it starts
    }

    /// One full cycle, awaited (tests, Sync Now). If this session's loop is running, another cycle follows and this
    /// waits for it; an older session's loop never makes it wait.
    public func syncNow() async {
        guard loopGeneration == generation, state.enabled else { return await run() }
        rerun = true
        await withCheckedContinuation { waiters.append($0) }   // await-ok: nothing follows; this session's loop resumes it
    }

    /// The store changed (its observer): send it shortly.
    public func localChanged() { localChanged(after: debounce) }

    func localChanged(after seconds: Double) {
        guard state.enabled, state.joined, automatic else { return }
        schedule(after: max(debounce, seconds))
    }

    // MARK: Sessions

    private func endSession() {
        scheduled?.cancel()
        pending = nil
        cancelInFlight()
    }

    /// Cancels the running loop (its task: a default retry sleep wakes) and its transport (no further request starts),
    /// and lets anyone waiting on it go.
    private func cancelInFlight() {
        loopTask?.cancel()
        loopTask = nil
        loopGeneration = nil
        transport?.cancel()
        transport = nil
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume() }
    }

    /// CloudKit's account-changed notification: the session in flight ends at once (its transport stops before its
    /// next request); the next cycle compares the account and stops sync if it's another one.
    public func accountDidChange() {
        generation += 1
        cancelInFlight()
        pending?.generation = generation
        syncSoon()
    }

    /// Whether the session `gen` is still the current one: sync on, and no Off, Cancel, account change or stop since.
    /// Every `await` in this file is followed at once by this check (or `live`), before anything changes;
    /// `testEveryAwaitInTheEngineIsFollowedByItsSessionCheck` holds the file to that.
    private func isLive(_ gen: Int) -> Bool { gen == generation && state.enabled }

    /// Throws `.cancelled` when the session `gen` is over (sync turned off, Cancel, an account change, a stop).
    private func live(_ gen: Int) throws {
        guard isLive(gen) else { throw SyncError.cancelled }
    }

    private func liveTransport() -> SyncGroupTransport {
        if let transport { return transport }
        let t = env.transport(state.device)
        transport = t
        return t
    }

    // MARK: Cycle

    private func run() async {
        guard state.enabled else { return }
        let gen = generation
        if loopGeneration == gen { rerun = true; return }
        loopGeneration = gen
        rerun = false
        // The task belongs to session `gen` from its creation: if that session ends before the task first runs (or
        // between cycles), it does nothing at all; it never adopts a newer session.
        let task = Task { [weak self] in
            while let self, !Task.isCancelled, self.isLive(gen) {
                self.rerun = false
                await self.cycle(gen)
                guard self.isLive(gen), self.rerun else { return }
            }
        }
        loopTask = task
        await task.value   // await-ok: the loop's own check follows (only its session's loop clears it)
        guard loopGeneration == gen else { return }   // superseded: the new session owns the loop and its waiters
        loopGeneration = nil
        loopTask = nil
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume() }
    }

    private func cycle(_ gen: Int) async {
        // Only the session this cycle was started for; the transport is made for it only now.
        guard isLive(gen) else { return }
        let t = liveTransport()
        if case .choosing = status {
            // The person is deciding. Only check that the Apple Account is still the one the choice is for.
            if let identity = try? await t.accountIdentity(), isLive(gen),
               let expected = pending?.account ?? state.account {
                if identity != expected { stop("You're signed in to another iCloud account now. Turn sync on to sync with it.") }
                else { pending?.generation = gen }
            }
            return
        }
        // Quiet while up to date or waiting for the key: the minute's retry shouldn't flash "Connecting".
        if status != .upToDate && status != .waitingForKeychain { status = state.joined ? .syncing : .connecting }
        do {
            await t.restore(checkpoint: state.checkpoint); try live(gen)
            try await t.prepare(); try live(gen)
            if let identity = try await t.accountIdentity() {
                try live(gen)
                if let known = state.account, known != identity {
                    return stop("You're signed in to another iCloud account now. Turn sync on to sync with it.")
                }
                state.account = identity
                // Every request of this session first checks it's still this account.
                await t.bind(account: identity); try live(gen)
            }
            guard state.joined, let group = state.group else {
                try await join(t, gen); try live(gen)
                if state.joined { try await t.verifyAccount(); try live(gen); finishCycle() }
                return
            }
            guard let key = try key ?? env.keys.key(group: group) else {
                status = .waitingForKeychain
                return schedule(after: 60)
            }
            self.key = key
            try await exchange(t, group: group, key: key, gen: gen); try live(gen)
            // Never "up to date" for an account the Mac no longer uses.
            try await t.verifyAccount(); try live(gen)
            finishCycle()
        } catch {
            // An old session's error (sync went off, the account changed meanwhile) mustn't replace the new state.
            guard isLive(gen) else { return }
            handle(error)
        }
    }

    private func finishCycle() {
        failures = 0
        state.lastSynced = env.now()
        trySave()
        if state.quarantine.isEmpty && state.malformed.isEmpty && state.notes.unreadable.isEmpty {
            status = .upToDate
        } else {
            let n = unreadableBatches
            status = .incomplete("\(n) change\(n == 1 ? "" : "s") from another Mac can't be read here (damaged, or from a newer Airc). Airc keeps them and tries again; updating Airc may help.")
        }
    }

    private func exchange(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async throws {
        // Callers awaited before: nothing here for a session that has ended meanwhile.
        try live(gen)
        // A quit or crash after remote changes reached the store, before the baseline was saved: apply again first.
        if let mode = state.applyMode { try apply(replace: mode == .replace, captureFirst: false) }
        try capture()
        try await upload(t, gen); try live(gen)
        let envelopes = try await t.read(); try live(gen)
        let report = await t.takeReadReport(); try live(gen)
        let notes = await t.takeNotes(); try live(gen)
        if report.zoneRecreated || (report.full && !state.uploaded.isSubset(of: report.own)) {
            state.recovery = true
            try save()
        }
        if state.recovery { try await recover(t, group: group, key: key, gen: gen); try live(gen) }
        // What was read is this account's before any of it reaches the store.
        try await t.verifyAccount(); try live(gen)
        // A malformed record is settled by a valid one of that name, or its deletion; a full read is the whole truth.
        if report.full { state.malformed = Set(report.malformed) } else {
            state.malformed.subtract(report.valid.union(report.deleted))
            state.malformed.formUnion(report.malformed)
        }
        let changed = merge(envelopes, retrying: quarantineSlice(), group: group, key: key)
        try integrate(notes, rowsChanged: changed, group: group, key: key)
        try save()
        // Only now: everything this read brought is in the saved replica and the store.
        await t.acknowledge(); try live(gen)
        let checkpoint = await t.checkpoint
        try live(gen)
        state.checkpoint = checkpoint
        try save()
        // What notes here still need (their latest text, their pictures), then what this cycle made (a conflicted copy, a
        // note kept against a removal) goes up.
        try await fetchNotes(t, group: group, key: key, gen: gen); try live(gen)
        try await fetchPictures(t, group: group, key: key, gen: gen); try live(gen)
        try await upload(t, gen); try live(gen)
        try? await publishDevice(t, group: group, key: key, gen: gen)
        try live(gen)
        await refreshDevices(t, group: group, key: key, gen: gen); try live(gen)
    }

    /// The quarantined batches this cycle retries: the first `quarantineRetryCount` (and `quarantineRetryBytes`);
    /// those that still fail go to the back, so every one gets its turn.
    private func quarantineSlice() -> [SyncEnvelope] {
        var slice: [SyncEnvelope] = [], bytes = 0
        for envelope in state.quarantine {
            guard slice.count < Self.quarantineRetryCount, bytes + envelope.sealed.count <= Self.quarantineRetryBytes || slice.isEmpty else { break }
            slice.append(envelope); bytes += envelope.sealed.count
        }
        return slice
    }

    /// Opens and merges the new batches and the retried quarantined ones into the replica; those that don't open or
    /// merge stay in (or join) the quarantine: kept, retried, reported. Returns whether the replica changed.
    private func merge(_ envelopes: [SyncEnvelope], retrying retried: [SyncEnvelope], group: UUID, key: SymmetricKey) -> Bool {
        var changed = false
        var bad: [SyncEnvelope] = []
        var settled = Set<UUID>()
        var seen = Set<UUID>()
        lastQuarantineRetries = retried.count
        for envelope in envelopes + retried where envelope.group == group && envelope.device != state.device && seen.insert(envelope.id).inserted {
            do {
                let ops = try envelope.open(group: group, key: key)
                let before = state.replica.operations.count
                try state.replica.receive(ops, now: millis)
                if state.replica.operations.count != before { changed = true }
                settled.insert(envelope.id)
            } catch {
                bad.append(envelope)
            }
        }
        // The rest of the quarantine (not retried this cycle) first, then this cycle's failures at the back.
        let retriedIDs = Set(retried.map(\.id))
        let untouched = state.quarantine.filter { !retriedIDs.contains($0.id) && !settled.contains($0.id) }
        state.quarantine = untouched + bad.filter { e in !untouched.contains { $0.id == e.id } }
        return changed
    }

    /// The server lost the zone: put the group record back (it must be this group's), send this Mac's whole history
    /// again, and check the record, before calling it recovered.
    private func recover(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async throws {
        for _ in 0..<3 {
            let winner = try await t.createGroup(try SyncGroupRecord.make(group: group, key: key, created: env.now()))
            try live(gen)
            guard winner.group == group else {
                stop("The sync data in iCloud now belongs to another group. Turn sync on to sync with it.")
                throw SyncError.cancelled
            }
            state.outbox = try seal(state.replica.log.filter { $0.stamp.device == state.device }, group: group, key: key)
            try recoverNotes(group: group, key: key)
            state.uploaded = []
            state.published = nil
            try save()
            try await upload(t, gen); try live(gen)
            let found = try await t.group(); try live(gen)
            let again = await t.takeReadReport(); try live(gen)
            if found?.group == group && !again.zoneRecreated {
                state.recovery = false
                try save()
                return
            }
        }
        throw SyncCloudFailure.other("recovery not finished")
    }

    // MARK: First sync

    private func join(_ t: SyncGroupTransport, _ gen: Int) async throws {
        if let found = try await t.group() {
            try live(gen)
            guard let key = try env.keys.key(group: found.group) else {
                status = .waitingForKeychain
                return schedule(after: 60)
            }
            guard found.verifies(key) else {
                status = .retrying("The sync key in iCloud Keychain doesn't match. Airc tries again.")
                return schedule(after: 300)
            }
            await t.restore(checkpoint: nil); try live(gen)
            let envelopes = try await t.read(); try live(gen)
            let report = await t.takeReadReport(); try live(gen)
            var remote = SyncReplica(device: state.device)
            var quarantine: [SyncEnvelope] = []
            for envelope in envelopes where envelope.group == found.group && envelope.device != state.device {
                do { try remote.receive(envelope.open(group: found.group, key: key), now: millis) }
                catch { quarantine.append(envelope) }
            }
            pending = Joining(group: found, key: key, remote: remote, quarantine: quarantine, malformed: Set(report.malformed),
                              account: state.account, generation: gen)
            if remote.sidebar.contains(where: { $0.id.kind == .space }) {
                status = .choosing(preview(remote, complete: quarantine.isEmpty && report.malformed.isEmpty))
            } else {
                try await finishJoin(t, .merge, profiles: [:], gen: gen); try live(gen)
            }
            return
        }
        // First Mac. The record is create-only: if another Mac got there first, join its group instead.
        try live(gen)
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        try env.keys.add(key, group: group)
        // Both paths check the session next. A lost race first removes the key made above: no record names it, so
        // nobody can use it, and it goes even if the session ended meanwhile.
        let winner = try await t.createGroup(try SyncGroupRecord.make(group: group, key: key, created: env.now()))   // await-ok: see above
        guard winner.group == group else {
            try? env.keys.removeUnused(group: group)
            try live(gen)
            return try await join(t, gen)
        }
        try live(gen)
        state.group = group
        state.joined = true
        state.replica = SyncReplica(device: state.device)
        state.adapter = SyncStoreAdapter()
        state.outbox = []
        state.uploaded = []
        state.notes = SyncNoteState()
        self.key = key
        try capture()
        // What another Mac sent meanwhile (it can join as soon as the record exists) is merged like any other change.
        try await exchange(t, group: group, key: key, gen: gen); try live(gen)
    }

    /// The person's answer on the first-sync screen. Backs up this Mac's sidebar first; returns that file. If that backup
    /// can't be written it throws `SyncFirstSyncBackupFailure` before anything is merged, replaced or sent, and the
    /// engine stays `.choosing` with the same choice open.
    @discardableResult
    public func choose(_ choice: SyncFirstSyncChoice, profiles: [String: SyncProfileChoice] = [:]) async throws -> URL {
        guard case .choosing = status, let joining = pending, joining.generation == generation, state.enabled else {
            throw SyncError.invalidOperation
        }
        if choice == .replace, !(joining.quarantine.isEmpty && joining.malformed.isEmpty) { throw SyncError.incompleteSnapshot }
        let t = liveTransport()
        let gen = generation
        do {
            // Still the account the choice was offered for: never apply or send it to another Apple ID.
            let identity = try await t.accountIdentity()
            try live(gen)
            if let identity, identity != joining.account {
                stop("You're signed in to another iCloud account now. Turn sync on to sync with it.")
                throw SyncError.cancelled
            }
            if let identity { await t.bind(account: identity); try live(gen) }
            // No backup, no first sync: the choice stays open (Merge or Replace again, or Cancel) and nothing changed.
            let backup: URL
            do { backup = try env.backup() } catch { throw SyncFirstSyncBackupFailure(underlying: error) }
            try await finishJoin(t, choice, profiles: profiles, gen: gen); try live(gen)
            try await t.verifyAccount(); try live(gen)
            finishCycle()
            return backup
        } catch {
            // A failed backup isn't a sync failure to retry: the first-sync screen stays, and its caller says why.
            if isLive(gen), !(error is SyncFirstSyncBackupFailure) { handle(error) }
            throw error
        }
    }

    /// Cancel on the first-sync screen: nothing changed; sync stays off.
    public func cancelFirstSync() {
        generation += 1
        endSession()
        status = .off
        state.enabled = false
        trySave()
    }

    private func finishJoin(_ t: SyncGroupTransport, _ choice: SyncFirstSyncChoice, profiles choices: [String: SyncProfileChoice],
                            gen: Int) async throws {
        guard let joining = pending else { return }
        try live(gen)
        let found = joining.group, key = joining.key, remote = joining.remote
        var adapter = SyncStoreAdapter()
        applying = true
        // Profiles: the same one (this Mac's own, synced back), the default one to the default one, then the choices
        // (several may share one local profile), else a new empty one (reused if a crash interrupted an earlier try).
        let descriptors = profileDescriptors(remote)
        let referenced = referencedProfiles(remote).filter { store.profile($0) == nil }
            .sorted { (descriptors[$0]?.isDefault == true ? 0 : 1, $0) < (descriptors[$1]?.isDefault == true ? 0 : 1, $1) }
        do {
            for group in referenced {
                if descriptors[group]?.isDefault == true {
                    adapter.mapProfile(local: store.defaultProfile.id, to: group)
                } else if case .use(let local)? = choices[group], store.profile(local) != nil {
                    adapter.mapProfile(local: local, to: group)
                } else {
                    adapter.mapProfile(local: try emptyProfile(for: group, descriptors[group]), to: group)
                }
            }
        } catch { applying = false; throw error }
        applying = false
        var replica = SyncReplica(device: state.device)
        var local: [SyncOperation] = []
        switch choice {
        case .merge:
            local = try adapter.capture(store.state, into: &replica, now: millis)
            try replica.receive(remote.log, now: millis)
        case .replace:
            try replica.receive(remote.log, now: millis)
        }
        state.group = found.group
        state.replica = replica
        state.adapter = adapter
        state.notes = SyncNoteState()
        state.outbox = try seal(local, group: found.group, key: key)
        state.uploaded = []
        state.quarantine = joining.quarantine
        state.malformed = joining.malformed
        state.checkpoint = nil
        state.joined = true
        self.key = key
        pending = nil
        // Already captured (merge), or this Mac's sidebar is what's being replaced: nothing to capture first.
        try apply(replace: choice == .replace, captureFirst: false)
        if choice == .replace {
            // Profiles that stay only on this Mac still describe themselves for Spaces moved to them later.
            state.adapter.forgetProfileDescriptions()
            // This Mac's pinned notes stayed (SyncMaterializer): they, their folders and Spaces go to the group.
            var adapter = state.adapter
            adapter.resurrect(items: SyncNotes.pinnedNotes(store.state).values.flatMap { $0 }, in: store.state, replica: state.replica)
            state.adapter = adapter
            try capture()
        }
        status = .syncing
        // A normal exchange from no checkpoint: uploads, then reads and merges everything again (nothing is lost if
        // another Mac wrote since the preview), and only then acknowledges.
        await t.restore(checkpoint: nil); try live(gen)
        try await exchange(t, group: found.group, key: key, gen: gen); try live(gen)
    }

    private func preview(_ remote: SyncReplica, complete: Bool) -> SyncFirstSync {
        let sidebar = remote.sidebar
        let spaces = sidebar.filter { $0.id.kind == .space }
        let rows = sidebar.filter { $0.id.kind == .row && $0[.kind] == .text("tab") }
        let iCloud = SyncFirstSync.Side(
            spaces: spaces.map { if case .text(let n)? = $0[.name] { n } else { "Space" } },
            pinned: rows.filter { if case .location(.pinned)? = $0[.location] { true } else { false } }.count,
            favorites: rows.filter { if case .location(.favorites)? = $0[.location] { true } else { false } }.count)
        let items = store.state.items.values.filter { $0.kind == .tab }
        let mine = SyncFirstSync.Side(spaces: store.orderedSpaces.map(\.name),
                                      pinned: items.filter { !$0.isFavorite && store.space($0.spaceID)?.isBlankWindow == false }.count,
                                      favorites: items.filter(\.isFavorite).count)
        let descriptors = profileDescriptors(remote)
        let defaultTaken = descriptors.values.contains(where: \.isDefault) ? store.defaultProfile.id : nil
        var profiles: [SyncFirstSync.Profile] = []
        var suggested = Set<String>()
        for group in referencedProfiles(remote).sorted() where store.profile(group) == nil && descriptors[group]?.isDefault != true {
            let d = descriptors[group]
            let name = d?.name ?? "Profile"
            let users = spaces.filter { $0[.profile] == .text(group) }.map { if case .text(let n)? = $0[.name] { n } else { "Space" } }
            // Same name, not already the default's, not suggested for another one: never two profiles in one by itself.
            let same = store.orderedProfiles.first {
                $0.id != defaultTaken && !suggested.contains($0.id)
                    && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if let same { suggested.insert(same.id) }
            profiles.append(.init(id: group, name: name, emoji: d?.emoji ?? "", spaces: users, suggestion: same?.id))
        }
        return SyncFirstSync(thisMac: mine, iCloud: iCloud, profiles: profiles, complete: complete, defaultProfile: defaultTaken)
    }

    private struct Descriptor { var name: String; var emoji: String; var isDefault: Bool }

    private func profileDescriptors(_ replica: SyncReplica) -> [String: Descriptor] {
        var result: [String: Descriptor] = [:]
        for record in replica.records.values where record.id.kind == .profile && !record.isDeleted {
            guard case .text(let name)? = record[.name] else { continue }
            let emoji: String = if case .text(let e)? = record[.icon] { e } else { "" }
            result[record.id.id] = Descriptor(name: name, emoji: emoji, isDefault: record[.kind] == .text("default"))
        }
        return result
    }

    private func referencedProfiles(_ replica: SyncReplica) -> Set<String> {
        var result = Set<String>()
        for record in replica.sidebar {
            if record.id.kind == .space, case .text(let p)? = record[.profile] { result.insert(p) }
            if record.id.kind == .row, case .location(.favorites(let p))? = record[.location] { result.insert(p) }
        }
        return result
    }

    /// The empty local profile for the group's `group` profile: one made for it before (its sourceID says so, e.g.
    /// after a crash between making it and saving the mapping), or a new one.
    private func emptyProfile(for group: String, _ d: Descriptor?, fallback: String = "Profile") throws -> String {
        let tag = "sync-profile:" + group
        if let existing = store.state.profiles.values.first(where: { $0.sourceID == tag }) { return existing.id }
        let id = try env.createProfile(uniqueProfileName(d?.name ?? fallback), d?.emoji ?? "")
        try store.updateProfile(id) { $0.sourceID = tag }
        return id
    }

    // MARK: Local and remote changes

    private var millis: Int64 { Int64(env.now().timeIntervalSince1970 * 1000) }

    /// This Mac's changes since the last capture → replica and outbox. Synchronous: nothing changes the store meanwhile.
    private func capture() throws {
        guard state.joined, let group = state.group, let key else { return }
        // Locals: two overlapping accesses to `state` (a class property) would trap at run time.
        var adapter = state.adapter, replica = state.replica
        let rows = try adapter.capture(store.state, into: &replica, now: millis)
        state.adapter = adapter
        state.replica = replica
        // Notes after rows: a removal's stamp is later than its row's tombstone (see restoreNotes).
        let notesBefore = state.notes
        try captureNotes()
        let settingsBefore = state.settings, boostsBefore = state.boosts
        let ops = try rows + captureUses(rows) + captureSettings() + captureBoosts()
        applySettings()
        applyBoosts()
        guard !ops.isEmpty || state.notes != notesBefore || state.settings != settingsBefore || state.boosts != boostsBefore
        else { return }
        if !ops.isEmpty { state.outbox += try seal(ops, group: group, key: key) }
        try save()
    }

    /// Applies the replica to the store, then takes the result as the adapter's baseline, so nothing applied is sent
    /// back. Journaled: the replica is saved with `applyMode` before the store changes, and cleared after.
    private func apply(replace: Bool, captureFirst: Bool = true) throws {
        if captureFirst { try capture() }
        state.applyMode = replace ? .replace : .merge
        try save()
        applying = true
        defer { applying = false }
        var adapter = state.adapter
        var result = try store.applySync(state.replica, adapter: &adapter, replace: replace)
        if !result.unresolvedProfiles.isEmpty, state.joined {
            // A profile another Mac made after the first sync: an empty one here, named after it. It has no logins.
            let descriptors = profileDescriptors(state.replica)
            for group in result.unresolvedProfiles.sorted() {
                if let id = try? emptyProfile(for: group, descriptors[group], fallback: "Profile from your other Mac") {
                    adapter.mapProfile(local: id, to: group)
                }
            }
            result = try store.applySync(state.replica, adapter: &adapter, replace: replace)
        }
        for change in result.profileChanges { env.applyProfileChange(change.space, change.profile) }
        adapter.rebase(store.state)
        state.adapter = adapter
        // Archive timing: Today tabs another Mac unpinned continue from its last use there.
        try store.applySyncedUses(state.replica, adapter: adapter)
        // Settings and Boosts: this Mac's changes first (the first sync's merge hasn't captured them), then the winners.
        if let key, let group = state.group, state.joined {
            let ops = try captureSettings() + captureBoosts()
            if !ops.isEmpty { state.outbox += try seal(ops, group: group, key: key) }
        }
        applySettings()
        applyBoosts()
        // Notes the group pinned or unpinned here: a baseline too, never sent back as this Mac's removal or pin.
        let pinned = SyncNotes.pinnedNotes(store.state)
        for id in state.notes.entries.keys { state.notes.entries[id]?.pinned = pinned[id] != nil }
        state.applyMode = nil
        try save()
    }

    private func uniqueProfileName(_ name: String) -> String {
        var candidate = name, n = 2
        while store.validateProfileName(candidate) == .taken { candidate = "\(name) \(n)"; n += 1 }
        return candidate
    }

    /// Batches of at most `maxBatchBytes` of operations (and `maxBatchOperations`). An operation that alone is too big
    /// (impossible after the adapter's caps) stays out rather than block the outbox for good.
    private func seal(_ ops: [SyncOperation], group: UUID, key: SymmetricKey) throws -> [SyncEnvelope] {
        // A note's row goes in a version 2 batch, which builds from before notes synced keep unread (SyncEnvelope).
        func isNoteRow(_ op: SyncOperation) -> Bool {
            guard op.record.kind == .row else { return false }
            if case .text(let url)? = op.fields[.url] ?? state.replica.records[op.record]?[.url] { return NoteURL.isNote(url) }
            return false
        }
        // A split's or a pane's goes in a version 3 batch (a note in a split too), which builds from before splits synced
        // keep unread in the same way.
        // A setting's goes in a version 4 batch of its own (SettingSyncPayload.swift); a Boost's, or a row's last use, in
        // a version 5 batch of its own (BoostSyncPayload.swift).
        func isVersion5(_ op: SyncOperation) -> Bool { op.record.kind == .boost || op.fields[.used] != nil }
        let boosts = ops.filter(isVersion5)
        let settings = ops.filter { $0.record.kind == .setting }
        let sidebar = ops.filter { $0.record.kind != .setting && !isVersion5($0) }
        let splits = sidebar.filter { SyncSplits.isSplitOperation($0, in: state.replica) }
        let rest = sidebar.filter { !SyncSplits.isSplitOperation($0, in: state.replica) }
        let notes = rest.filter(isNoteRow)
        let others = rest.filter { !isNoteRow($0) }
        return try seal(others, version: 1, group: group, key: key) + seal(notes, version: 2, group: group, key: key)
            + seal(splits, version: SyncSplits.envelopeVersion, group: group, key: key)
            + seal(settings, version: SyncSettings.envelopeVersion, group: group, key: key)
            + seal(boosts, version: SyncBoosts.envelopeVersion, group: group, key: key)
    }

    // MARK: Boosts and archive timing

    /// This Mac's Boosts (and deletions) it hasn't said yet → replica. Returns the operations (the caller seals them).
    private func captureBoosts() throws -> [SyncOperation] {
        guard !state.boosts.off, let source = env.boosts else { return [] }
        var replica = state.replica, baseline = state.boosts.baseline
        var ops: [SyncOperation] = []
        for (site, payload) in source.current(env.deviceName).sorted(by: { $0.key < $1.key }) {
            // Too large, or not a site: stays on this Mac.
            guard SyncBoosts.isValidSite(site), payload.isValid, baseline[site] != payload.content else { continue }
            ops.append(try replica.edit(SyncRecordID(.boost, site), [.value: .boost(payload)], now: millis))
            baseline[site] = payload.content
        }
        state.replica = replica
        state.boosts.baseline = baseline
        return ops
    }

    /// Each site's winning Boost that this Mac hasn't applied (nor sent) yet → the app. A newer format waits.
    private func applyBoosts() {
        guard !state.boosts.off, let source = env.boosts else { return }
        var incoming: [String: BoostSyncPayload] = [:]
        for record in state.replica.records.values where record.id.kind == .boost {
            guard case .boost(let p)? = record[.value], p.isReadable, state.boosts.baseline[record.id.id] != p.content else { continue }
            incoming[record.id.id] = p
        }
        guard !incoming.isEmpty else { return }
        let was = applying
        applying = true
        defer { applying = was }
        for site in source.apply(incoming) {
            if let p = incoming[site] { state.boosts.baseline[site] = p.content }
        }
    }

    /// Rows this capture unpinned whose page stayed here as a Today tab: when it was last used here, so a Mac that keeps
    /// the page continues its archive timer from there (`SpacesStore.applySyncedUses`). One operation per unpin, never
    /// per use.
    private func captureUses(_ rows: [SyncOperation]) throws -> [SyncOperation] {
        let unpinned = Set(rows.filter { $0.record.kind == .row && $0.fields[.location] == .location(.archived) }.map(\.record))
        guard !unpinned.isEmpty else { return [] }
        var replica = state.replica
        var ops: [SyncOperation] = []
        for tab in store.state.tabs.values.sorted(by: { $0.id < $1.id }) where tab.isToday {
            guard let record = state.adapter.record(forTab: tab.id), unpinned.contains(SyncRecordID(.row, record)) else { continue }
            let used = Int64(max(0, tab.lastActiveAt.timeIntervalSince1970 * 1000))
            ops.append(try replica.edit(SyncRecordID(.row, record), [.used: .time(used)], now: millis))
        }
        state.replica = replica
        return ops
    }

    // MARK: Settings

    /// The group's ID of a local profile, and back (nil: not on this Mac).
    private func groupProfile(_ local: String) -> String? { state.adapter.groupProfiles[local] ?? local }
    private func localProfile(_ group: String) -> String? {
        state.adapter.localProfiles[group] ?? (store.profile(group) != nil ? group : nil)
    }

    /// This Mac's changed settings that it hasn't said yet → replica. Returns the operations (the caller seals them).
    private func captureSettings() throws -> [SyncOperation] {
        guard !state.settings.off, let source = env.settings else { return [] }
        var replica = state.replica, baseline = state.settings.baseline
        var ops: [SyncOperation] = []
        for (key, entry) in source.explicit().sorted(by: { $0.key < $1.key }) {
            guard let group = SyncSettings.mapped(key, groupProfile), SyncSettings.isSynced(group), baseline[group] != entry.json else { continue }
            let payload = SettingSyncPayload(json: entry.json, changed: entry.changed)
            // Too large: stays on this Mac.
            guard payload.isValid else { continue }
            ops.append(try replica.edit(SyncRecordID(.setting, group), [.value: .setting(payload)], now: millis))
            baseline[group] = entry.json
        }
        state.replica = replica
        state.settings.baseline = baseline
        return ops
    }

    /// Each synced setting's winner that this Mac hasn't applied (nor sent) yet → the app. A setting of a profile this
    /// Mac doesn't have, from a newer format, or one the app can't read waits (and is tried again).
    private func applySettings() {
        guard !state.settings.off, let source = env.settings else { return }
        var incoming: [String: SyncSettingEntry] = [:], groupKey: [String: String] = [:]
        for record in state.replica.records.values where record.id.kind == .setting {
            guard case .setting(let p)? = record[.value], p.isReadable, SyncSettings.isSynced(record.id.id),
                  state.settings.baseline[record.id.id] != p.json, let local = SyncSettings.mapped(record.id.id, localProfile)
            else { continue }
            incoming[local] = SyncSettingEntry(json: p.json, changed: p.changed)
            groupKey[local] = record.id.id
        }
        guard !incoming.isEmpty else { return }
        // The app may change the store (a profile's archive timing, the sidebar's side): not this Mac's edit.
        let was = applying
        applying = true
        defer { applying = was }
        for local in source.apply(incoming) {
            if let group = groupKey[local], let entry = incoming[local] { state.settings.baseline[group] = entry.json }
        }
    }

    private func seal(_ ops: [SyncOperation], version: Int, group: UUID, key: SymmetricKey) throws -> [SyncEnvelope] {
        // Counted as sealed: the JSON array's brackets and commas, and AES-GCM's 12-byte nonce and 16-byte tag.
        let overhead = 2 + 28
        var batches: [[SyncOperation]] = []
        var batch: [SyncOperation] = [], bytes = overhead
        let encoder = JSONEncoder()
        for op in ops {
            let size = try encoder.encode(op).count + 1
            // Can't happen: the adapter caps every value (16 KB URL, 2 KB texts), so one operation is far smaller.
            guard overhead + size <= Self.maxBatchBytes else { continue }
            if !batch.isEmpty, bytes + size > Self.maxBatchBytes || batch.count >= Self.maxBatchOperations {
                batches.append(batch); batch = []; bytes = overhead
            }
            batch.append(op); bytes += size
        }
        if !batch.isEmpty { batches.append(batch) }
        return try batches.map { try SyncEnvelope.seal($0, group: group, device: state.device, key: key, version: version) }
    }

    /// Pictures first (a note never arrives before them), then note removals, then the batches (rows), then notes' text:
    /// a Mac that reads a row's tombstone has its note's removal too (restoreNotes), and one that reads a note's text has
    /// its row.
    private func upload(_ t: SyncGroupTransport, _ gen: Int) async throws {
        holdingNotes = false
        try await uploadPictures(t, gen); try live(gen)
        try await uploadNotes(t, gen, removals: true); try live(gen)
        try await uploadBatches(t, gen); try live(gen)
        try await uploadNotes(t, gen, removals: false); try live(gen)
        notesHeld = holdingNotes
    }

    private func uploadBatches(_ t: SyncGroupTransport, _ gen: Int) async throws {
        while let envelope = state.outbox.first {
            try live(gen)
            // The outbox goes up only once it's on disk: after a failed save, save again first (or stop here).
            if unsaved { try save() }
            try await t.append(envelope)
            // An obsolete session's upload that returned late changes no bookkeeping (the new session re-sends it; the
            // save is idempotent).
            try live(gen)
            if state.outbox.first == envelope { state.outbox.removeFirst() }
            state.uploaded.insert(envelope.id)
            try save()
        }
    }

    // MARK: Notes

    /// This Mac's note changes since the last capture (after the rows'): a version for each pinned note whose text or
    /// title changed here, or that was pinned again here after a removal; a removal for each that stopped being pinned
    /// here by a local change. What another Mac changed is never sent back (`apply` and `integrate` update the baseline).
    private func captureNotes() throws {
        guard state.joined, state.group != nil, key != nil else { return }
        let pinned = SyncNotes.pinnedNotes(store.state)
        for id in pinned.keys.sorted() {
            guard let note = store.state.notes[id] else { continue }
            guard let e = state.notes.entries[id] else { try ownVersion(id); continue }
            // A newer text from another Mac that isn't here yet: only an edit made on what's here is sent (a conflict).
            let unseen = !e.removed && e.shown != e.known
            // The digest decides, never `updatedAt` alone: two edits in one clock tick (or a clock set back) look the same.
            let edited = e.digest != SyncNotes.digest(note) && !(unseen && note.isEmpty)
            if edited || (e.removed && !e.pinned) {
                try ownVersion(id)
            } else {
                if unseen { state.notes.refetch.insert(id) }
                if !e.pinned { state.notes.entries[id]?.pinned = true }
            }
        }
        for (id, e) in state.notes.entries.sorted(by: { $0.key < $1.key }) where e.pinned && pinned[id] == nil {
            if e.removed { state.notes.entries[id]?.pinned = false } else { try ownVersion(id, removed: true) }
        }
    }

    /// A new version of note `id` by this Mac (its text from the store, or a removal), queued for upload. It builds on
    /// what this Mac has seen: a newer text it doesn't show yet isn't in its vector, so that edit stays a conflict.
    private func ownVersion(_ id: String, removed: Bool = false) throws {
        guard let group = state.group, let key else { return }
        let note = store.state.notes[id]
        guard removed || note != nil else { return }
        let old = state.notes.entries[id]
        let base = old.map { !$0.removed && $0.shown != $0.known ? ($0.shown ?? SyncNoteVector()) : $0.known } ?? SyncNoteVector()
        let vector = base.incremented(state.device)
        let stamp = try state.replica.tick(now: millis)
        let version = SyncNoteVersion(note: id, stamp: stamp, vector: vector, removed: removed, title: note?.title,
                                      document: note?.document, created: note?.createdAt, updated: note?.updatedAt)
        var e = old ?? SyncNoteState.Entry(known: vector, head: stamp, headVector: vector, removed: removed)
        e.known = e.known.merged(vector)
        e.head = stamp
        e.headVector = vector
        e.removed = removed
        e.pinned = !removed
        if !removed, let note {
            e.shown = e.known
            e.digest = SyncNotes.digest(note)
            e.updated = note.updatedAt
        }
        state.notes.entries[id] = e
        try queue(version, group: group, key: key)
    }

    private func queue(_ version: SyncNoteVersion, group: UUID, key: SymmetricKey) throws {
        let id = version.note
        let record = try SyncNoteRecord.seal(version, group: group, device: state.device, key: key)
        guard record.sealed.count <= SyncNotes.maxNoteBytes else {
            // Far past any real note (pictures don't count): its row syncs, its text stays here; Settings says so.
            state.notes.tooLarge.insert(id)
            state.notes.outbox[id] = nil
            return
        }
        state.notes.tooLarge.remove(id)
        state.notes.outbox[id] = .init(record: record, removed: version.removed)
        for file in version.document?.imageFiles.sorted() ?? [] where !state.notes.picturesUp.contains(file) {
            state.notes.pictureOutbox.insert(file)
        }
    }

    /// What a read brought for notes, in one step with the rows (no await in between, so nothing local slips through):
    /// this Mac's edits are captured first, other Macs' versions decided against them, notes kept against a removal
    /// they didn't see are re-created, the rows applied, then the winning texts, then the conflicted copies.
    private func integrate(_ records: [SyncNoteRecord], rowsChanged: Bool, group: UUID, key: SymmetricKey) throws {
        try capture()
        let work = receiveNotes(records, group: group, key: key)
        if !work.restore.isEmpty { try restoreNotes(work.restore) }
        if rowsChanged || !work.restore.isEmpty { try apply(replace: false, captureFirst: false) }
        try applyNoteText(work.text)
        for copy in work.copies {
            try store.createConflictedCopy(of: copy.id, title: copy.title, document: copy.document, device: env.deviceName)
        }
        if !work.copies.isEmpty { try capture() }
    }

    private struct NoteWork {
        /// The winning version whose text goes into the store, per note.
        var text: [String: SyncNoteVersion] = [:]
        /// This Mac's texts that lost a conflict: they become notes of their own.
        var copies: [(id: String, title: String?, document: NoteDocument)] = []
        /// This Mac's notes another Mac removed without seeing their latest edit: kept, and sent again.
        var restore: Set<String> = []
    }

    /// Decides each other Mac's version against what this Mac has (docs/sync.md, "Conflicts"). Last writer wins per note
    /// (the later stamp); an edit wins over a removal it didn't see, whatever the stamps; the Mac whose own text lost
    /// keeps it as a conflicted copy, so no text is ever lost. Every Mac decides alike, so they all end with one text.
    private func receiveNotes(_ records: [SyncNoteRecord], group: UUID, key: SymmetricKey) -> NoteWork {
        var work = NoteWork()
        var versions: [SyncNoteVersion] = []
        for record in records where record.device != state.device {
            if let version = try? record.open(group: group, key: key) {
                versions.append(version)
                state.notes.unreadable.remove(record.name)
            } else if record.group == group {
                // Damaged, or from a newer Airc: fetched again every cycle (an update may read it), and reported.
                state.notes.unreadable.insert(record.name)
            }
        }
        let pinned = SyncNotes.pinnedNotes(store.state)
        for v in versions.sorted(by: { $0.stamp < $1.stamp }) {
            let id = v.note
            // Edits made after this one stamp later (a row re-created for a kept note beats the removal's tombstone).
            try? state.replica.observe(v.stamp, now: millis)
            guard var e = state.notes.entries[id] else {
                var entry = SyncNoteState.Entry(known: v.vector, head: v.stamp, headVector: v.vector, removed: v.removed)
                entry.pinned = pinned[id] != nil
                state.notes.entries[id] = entry
                if !v.removed { work.text[id] = v }
                continue
            }
            switch v.vector.compare(e.known) {
            case .same, .older:
                // Known already; still the text this Mac lacks (a fetch for a note whose text didn't come with it).
                if v.stamp == e.head, !v.removed, e.shown != e.known { work.text[id] = v }
                continue
            case .newer:
                e.known = v.vector
                e.head = v.stamp
                e.headVector = v.vector
                e.removed = v.removed
                if !v.removed { work.text[id] = v } else { work.text[id] = nil }
            case .concurrent:
                let merged = e.known.merged(v.vector)
                let theirsWins = e.removed != v.removed ? !v.removed : e.head < v.stamp
                if theirsWins {
                    // This Mac's own text lost: it stays, as a note of its own (only its author makes the copy).
                    if !e.removed, e.head.device == state.device, e.shown == e.known, let note = store.state.notes[id],
                       SyncNotes.digest(note) == e.digest, v.digest != e.digest {
                        work.copies.append((id, note.title, note.document))
                    }
                    e.known = merged
                    e.head = v.stamp
                    e.headVector = v.vector
                    e.removed = false
                    work.text[id] = v
                } else {
                    if e.shown == e.known { e.shown = merged }
                    e.known = merged
                    // A removal that didn't see this Mac's edit: the edit wins; its author keeps the note pinned, everywhere.
                    if !e.removed, v.removed, e.head.device == state.device { work.restore.insert(id) }
                }
            }
            state.notes.entries[id] = e
        }
        return work
    }

    /// Notes another Mac removed without seeing this Mac's edit: their rows (with their folders and Space, if those went
    /// too) are sent again with newer stamps, and a new version of each, so every Mac keeps them.
    private func restoreNotes(_ ids: Set<String>) throws {
        let pinned = SyncNotes.pinnedNotes(store.state)
        var adapter = state.adapter
        adapter.resurrect(items: ids.flatMap { pinned[$0] ?? [] }, in: store.state, replica: state.replica)
        state.adapter = adapter
        for id in ids.sorted() {
            // Its row went here already (an older read): pinned again, at the bottom of the first Space.
            if pinned[id] == nil, store.state.notes[id] != nil { try store.repinNote(id) }
            try ownVersion(id)
        }
        try capture()
    }

    /// The winners' texts into the store, for notes this Mac shows (a pinned row, a Today tab, the Archive). Others wait
    /// until a row comes; then the text is fetched by name (`refetch`).
    private func applyNoteText(_ text: [String: SyncNoteVersion]) throws {
        let referenced = store.referencedNoteIDs
        applying = true
        defer { applying = false }
        for (id, v) in text.sorted(by: { $0.key < $1.key }) {
            guard var e = state.notes.entries[id], !e.removed, e.head == v.stamp, let document = v.document,
                  referenced.contains(id) else { continue }
            try store.applySyncedNote(id, title: v.title, document: document, created: v.created, updated: v.updated)
            e.shown = e.known
            e.digest = v.digest
            e.updated = store.state.notes[id]?.updatedAt
            state.notes.entries[id] = e
            state.notes.refetch.remove(id)
            for file in document.imageFiles.sorted() where env.notePictures?.has(file) == false && !state.notes.picturesWanted.contains(file) {
                state.notes.picturesWanted.append(file)
            }
        }
        for (id, e) in state.notes.entries where !e.removed && e.shown != e.known && referenced.contains(id) {
            state.notes.refetch.insert(id)
        }
        state.notes.refetch = state.notes.refetch.filter { id in
            state.notes.entries[id].map { !$0.removed && $0.shown != $0.known } ?? false
        }
    }

    /// The zone was lost: this Mac uploads again what it holds of every note (its latest version, whoever made it) and
    /// every picture of them.
    private func recoverNotes(group: UUID, key: SymmetricKey) throws {
        state.notes.outbox = [:]
        state.notes.picturesUp = []
        for (id, e) in state.notes.entries.sorted(by: { $0.key < $1.key }) {
            if e.removed {
                if e.head.device == state.device {
                    try queue(SyncNoteVersion(note: id, stamp: e.head, vector: e.headVector, removed: true), group: group, key: key)
                }
                continue
            }
            guard e.shown == e.known, let note = store.state.notes[id], SyncNotes.digest(note) == e.digest else { continue }
            try queue(SyncNoteVersion(note: id, stamp: e.head, vector: e.headVector, removed: false, title: note.title,
                                      document: note.document, created: note.createdAt, updated: note.updatedAt), group: group, key: key)
        }
    }

    private func uploadPictures(_ t: SyncGroupTransport, _ gen: Int) async throws {
        guard let group = state.group, let key, !state.notes.pictureOutbox.isEmpty else { return }
        guard let pictures = env.notePictures else { state.notes.pictureOutbox = []; return }
        for file in state.notes.pictureOutbox.sorted() {
            try live(gen)
            // Gone from this Mac, or too large: it stays out; other Macs show "Picture not on this Mac".
            guard let data = pictures.data(file), data.count <= SyncNotes.maxPictureBytes else {
                state.notes.pictureOutbox.remove(file)
                continue
            }
            if unsaved { try save() }
            let asset = try SyncNoteAsset.seal(data, file: file, group: group, key: key)
            do {
                try await t.saveAsset(asset)
                try live(gen)
            } catch let failure as SyncCloudFailure where Self.holdsNotes(failure) {
                try live(gen)
                holdingNotes = true
                return
            }
            state.notes.pictureOutbox.remove(file)
            state.notes.picturesUp.insert(file)
            try save()
        }
    }

    private func uploadNotes(_ t: SyncGroupTransport, _ gen: Int, removals: Bool) async throws {
        for (id, outgoing) in state.notes.outbox.sorted(by: { $0.key < $1.key }) where outgoing.removed == removals {
            try live(gen)
            if unsaved { try save() }
            do {
                try await t.saveNote(outgoing.record)
                try live(gen)
            } catch let failure as SyncCloudFailure where Self.holdsNotes(failure) {
                try live(gen)
                holdingNotes = true
                return
            }
            // A newer version queued meanwhile stays queued.
            if state.notes.outbox[id] == outgoing { state.notes.outbox[id] = nil }
            try save()
        }
    }

    /// A failure that keeps notes waiting without stopping the rest of sync: iCloud refusing the note record types (not
    /// deployed in this container yet), or a record it won't take. Network, account, quota and zone failures go to
    /// `handle` as for any upload.
    static func holdsNotes(_ failure: SyncCloudFailure) -> Bool {
        switch failure {
        // A missing type can come back as a permission failure: the entitlement itself was checked before any upload.
        case .other, .limitExceeded, .notFound, .serverRecordChanged, .missingEntitlement: true
        default: false
        }
    }

    /// Texts this Mac needs (a row here, the latest text not) and records it couldn't read, by name; then decided and
    /// applied like a read.
    private func fetchNotes(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async throws {
        let unreadable = Array(state.notes.unreadable.sorted().prefix(32))
        var names = Set(unreadable)
        for id in state.notes.refetch.sorted().prefix(32) {
            for device in state.notes.entries[id]?.known.devices ?? [] where device != state.device {
                names.insert(SyncCloudSchema.noteName(device: device, note: id))
            }
        }
        guard !names.isEmpty else { return }
        let records = try await t.fetchNotes(names.sorted())
        try live(gen)
        // A record that isn't there any more can't be read either.
        let found = Set(records.map(\.name))
        for name in unreadable where !found.contains(name) { state.notes.unreadable.remove(name) }
        try integrate(records, rowsChanged: false, group: group, key: key)
        try save()
    }

    /// Pictures the notes here show that aren't on this Mac: fetched, opened, checked against their names, kept.
    private func fetchPictures(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async throws {
        guard let pictures = env.notePictures else { state.notes.picturesWanted = []; return }
        state.notes.picturesWanted.removeAll { pictures.has($0) }
        let batch = Array(state.notes.picturesWanted.prefix(SyncNotes.picturesPerCycle))
        guard !batch.isEmpty else { return }
        var files: [String: String] = [:]
        for file in batch { files[SyncNoteAsset.name(for: file, key: key)] = file }
        let assets = try await t.fetchAssets(files.keys.sorted())
        try live(gen)
        var arrived: [String] = []
        for asset in assets {
            guard let file = files[asset.name], let data = try? asset.open(file: file, group: group, key: key) else { continue }
            try pictures.save(data, file: file)
            state.notes.picturesUp.insert(file)
            arrived.append(file)
        }
        // Those that didn't come (not uploaded yet, too large on their Mac) go to the back: every one gets its turn.
        let missing = batch.filter { !arrived.contains($0) }
        state.notes.picturesWanted.removeAll { batch.contains($0) }
        state.notes.picturesWanted += missing
        try save()
        if !arrived.isEmpty { env.picturesArrived?(arrived) }
    }

    // MARK: Devices

    nonisolated private static func deviceAuthentication(_ group: UUID, _ device: UUID) -> Data {
        Data("Airc-sync-device|\(group.uuidString)|\(device.uuidString)".utf8)
    }

    /// A device record's sealed name: only the group's Macs can read it, and it can't be moved to another device.
    nonisolated public static func sealDeviceName(_ name: String, group: UUID, device: UUID, key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(Data(name.utf8), using: key, authenticating: deviceAuthentication(group, device)).combined else {
            throw SyncError.invalidEnvelope
        }
        return sealed
    }

    private func publishDevice(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async throws {
        if let last = state.published, env.now().timeIntervalSince(last) < 6 * 3600 { return }
        let sealed = try Self.sealDeviceName(env.deviceName, group: group, device: state.device, key: key)
        try await t.publish(SyncDeviceRecord(group: group, device: state.device, sealed: sealed, seen: env.now()))
        try live(gen)
        state.published = env.now()
        try save()
    }

    private func refreshDevices(_ t: SyncGroupTransport, group: UUID, key: SymmetricKey, gen: Int) async {
        let records = await t.devices
        guard isLive(gen) else { return }
        devices = records.filter { $0.group == group }.compactMap { record in
            guard let box = try? AES.GCM.SealedBox(combined: record.sealed),
                  let name = try? AES.GCM.open(box, using: key, authenticating: Self.deviceAuthentication(group, record.device)) else { return nil }
            return Device(id: record.device, name: String(decoding: name, as: UTF8.self), seen: record.seen, isThisMac: record.device == state.device)
        }.sorted { ($0.isThisMac ? 0 : 1, $0.name) < ($1.isThisMac ? 0 : 1, $1.name) }
    }

    // MARK: Failures

    private func handle(_ error: Error) {
        // The session ended (off, Cancel, another account): its status is already set, nothing to retry.
        if error as? SyncError == .cancelled { return }
        failures += 1
        let wait = min(900, 5 * pow(3, Double(min(failures, 6) - 1)))
        switch error {
        case let failure as SyncCloudFailure:
            switch failure {
            case .network(let after):
                status = .retrying("Can't reach iCloud right now. Airc tries again by itself.")
                schedule(after: max(wait, after ?? 0))
            case .notSignedIn:
                status = .unavailable("Sign in to iCloud in System Settings to sync.")
                schedule(after: 300)
            case .restricted:
                status = .unavailable("iCloud is restricted on this Mac.")
            case .quotaExceeded:
                status = .retrying("Your iCloud storage is full. Airc tries again later.")
                schedule(after: 1800)
            case .userDeletedZone:
                stop("Airc's iCloud data was deleted. Turn sync on to upload this Mac's sidebar again.")
            case .accountChanged:
                stop("You're signed in to another iCloud account now. Turn sync on to sync with it.")
            case .missingEntitlement:
                status = .unavailable(Self.notSetUp)
            default:
                status = .retrying("Couldn't sync with iCloud. Airc tries again by itself.")
                schedule(after: wait)
            }
        case is SyncKeyError:
            status = .retrying("Can't read the sync key from iCloud Keychain. Airc tries again when the Mac is unlocked.")
            schedule(after: 60)
        case is CocoaError, is POSIXError:
            status = .retrying("Airc can't save its sync state on this Mac (is the disk full?). Nothing more is sent until it can.")
            schedule(after: wait)
        default:
            status = .retrying("Couldn't sync. Airc tries again by itself.")
            schedule(after: wait)
        }
    }

    public static let notSetUp = "iCloud sync is available in release builds once set up."

    /// Turns sync off and forgets this Mac's sync state (never the shared key, never the sidebar itself).
    private func stop(_ message: String) {
        generation += 1
        endSession()
        key = nil
        state = State(device: UUID(), machine: env.machine)
        trySave()
        devices = []
        status = .stopped(message)
    }

    private func schedule(after seconds: Double) {
        guard automatic else { return }
        scheduled?.cancel()
        let sleep = env.sleep
        scheduled = Task { [weak self] in
            await sleep(seconds)   // await-ok: a timer; no engine state
            guard !Task.isCancelled else { return }
            await self?.run()   // await-ok: run() takes the session current when it starts
        }
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: env.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: env.stateURL, options: [.atomic])
            unsaved = false
        } catch {
            unsaved = true
            throw error
        }
    }

    /// Where a failed save can't lose anything (the switch, a stop): the next cycle saves again or starts over.
    private func trySave() { try? save() }
}

/// Notes in sync (NoteSyncPayload.swift): per note what this Mac knows, shows and owes. In the engine's state file.
struct SyncNoteState: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Every version of the note this Mac has seen or made, merged.
        var known: SyncNoteVector
        /// The version that won (its author is `head.device`), its own vector, and whether it's a removal.
        var head: SyncStamp
        var headVector: SyncNoteVector
        var removed: Bool
        /// The version the store's text is (nil: the store doesn't have it), that text's digest and the note's
        /// `updatedAt` then (a quick check before the digest).
        var shown: SyncNoteVector?
        var digest: String?
        var updated: Date?
        /// Pinned here at the last capture or apply: a removal is sent only when a local change unpins it.
        var pinned = false

        init(known: SyncNoteVector, head: SyncStamp, headVector: SyncNoteVector, removed: Bool) {
            self.known = known; self.head = head; self.headVector = headVector; self.removed = removed
        }
    }

    struct Outgoing: Codable, Equatable {
        var record: SyncNoteRecord
        var removed: Bool
    }

    var entries: [String: Entry] = [:]
    /// This Mac's records waiting for upload: the latest per note. Survives a quit.
    var outbox: [String: Outgoing] = [:]
    /// Pictures to upload, and pictures known to be in iCloud (uploaded or fetched).
    var pictureOutbox: Set<String> = []
    var picturesUp: Set<String> = []
    /// Pictures notes here show that aren't on this Mac yet, in the order they're fetched.
    var picturesWanted: [String] = []
    /// Notes with a row here whose latest text isn't: fetched by name.
    var refetch: Set<String> = []
    /// Note records that can't be read here (damaged, or a newer format): fetched again, and reported.
    var unreadable: Set<String> = []
    /// Notes whose text is too large to sync (SyncNotes.maxNoteBytes).
    var tooLarge: Set<String> = []
}

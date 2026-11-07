// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// Keeps every profile's engine profile loaded (SP-1: all profiles stay loaded) and makes new
/// profiles instant (SP-11): one spare engine profile is prepared ahead and handed out on create.
///
/// The spare (code review H6) has one folder name, persisted in the store and reused on every launch until New Profile
/// adopts it, so no orphan folders pile up. It loads when a profile might be created (Create Profile, the New Space
/// card's profile menu), not at launch: an unused profile costs its services' memory, and its renderer would take the
/// warm spare process from the user's own profile. Every spare folder Airc creates is recorded; `removeOrphanSpares`
/// deletes recorded ones that no profile uses, and never anything else.
final class ProfileHost {
    let store: SpacesStore
    let engine: BrowserEngine
    private var loaded: [String: EngineProfile] = [:]      // profile ID → engine profile
    private var waiting: [String: [(EngineProfile?) -> Void]] = [:]
    /// A pre-created engine folder waiting for the next new profile.
    private var spare: (directory: String, profile: EngineProfile)?
    private var preparingSpare = false
    private static let spareKey = "spareEngineDirectory"
    private static let createdSparesKey = "createdSpareEngineDirectories"
    /// Each engine profile as it loads (the window applies per-profile engine settings, e.g. MEM-3's timeout).
    var didLoad: ((EngineProfile) -> Void)?
    /// Each engine profile as it loads, for the app's profile keeper (WIN-7, AppDelegate.keepProfilesLoaded): kept apart
    /// from `didLoad`, which others chain.
    var keepLoaded: ((EngineProfile) -> Void)?

    init(store: SpacesStore, engine: BrowserEngine) {
        self.store = store
        self.engine = engine
    }

    func loadAll(completion: @escaping () -> Void) {
        let profiles = store.orderedProfiles
        var remaining = profiles.count
        guard remaining > 0 else { return completion() }
        for p in profiles {
            load(p) { _ in
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func engineProfile(for profileID: String) -> EngineProfile? { loaded[profileID] }

    /// The Airc profile an engine profile belongs to.
    func profileID(for engineProfile: EngineProfile) -> String? {
        loaded.first { $0.value === engineProfile }?.key
    }
    var loadedProfiles: [EngineProfile] { Array(loaded.values) }

    /// Runs `block` once the profile's engine profile is loaded (immediately if it is). `failed` runs instead when the
    /// profile doesn't exist or its engine profile can't load.
    func whenLoaded(_ profileID: String, _ block: @escaping (EngineProfile) -> Void, failed: (() -> Void)? = nil) {
        if let p = loaded[profileID] { return block(p) }
        guard let profile = store.profile(profileID) else { failed?(); return }
        load(profile) { e in if let e { block(e) } else { failed?() } }
    }

    private func load(_ p: Profile, _ done: @escaping (EngineProfile?) -> Void) {
        if let e = loaded[p.id] { return done(e) }
        if waiting[p.id] != nil {
            waiting[p.id]!.append(done)
            return
        }
        waiting[p.id] = [done]
        engine.loadProfile(directory: p.engineDirectory) { [weak self] e in
            guard let self else { return }
            let blocks = self.waiting.removeValue(forKey: p.id) ?? []
            if let e {
                self.loaded[p.id] = e
                self.keepLoaded?(e)
                self.didLoad?(e)
            }
            blocks.forEach { $0(e) }
        }
    }

    /// The spare's folder name, kept across launches until New Profile adopts it.
    private(set) var spareDirectory: String? {
        get { store.localValue(Self.spareKey) }
        set { store.setLocalValue(Self.spareKey, newValue) }
    }

    /// Every spare folder Airc created and no profile has adopted yet.
    private var createdSpares: [String] {
        get { (store.localValue(Self.createdSparesKey)?.split(separator: "\n").map(String.init)) ?? [] }
        set { store.setLocalValue(Self.createdSparesKey, newValue.isEmpty ? nil : newValue.joined(separator: "\n")) }
    }

    /// Loads the spare engine profile (creating its folder the first time) and warms its renderer.
    func prepareSpare() {
        guard spare == nil, !preparingSpare else { return }
        let dir: String
        if let d = spareDirectory, !store.storedProfileUses(engineDirectory: d) {
            dir = d
        } else {
            var d = "Profile-" + newID().prefix(8)
            while store.storedProfileUses(engineDirectory: d) { d = "Profile-" + newID().prefix(8) }
            dir = d
            // Recorded before the engine creates the folder, so a crash can't leave an unrecorded one.
            createdSpares = createdSpares.filter { $0 != dir } + [dir]
            spareDirectory = dir
        }
        preparingSpare = true
        engine.loadProfile(directory: dir) { [weak self] e in
            guard let self else { return }
            self.preparingSpare = false
            guard let e, self.spare == nil, self.spareDirectory == dir else { return }
            e.warmSpareRenderer()
            self.spare = (dir, e)
        }
    }

    /// Creates a profile in the store and binds it to the spare engine profile, so it is usable in
    /// the same frame. A spare folder from an earlier launch is adopted even when it isn't loaded yet.
    func createProfile(name: String, emoji: String, color: RGBA?) throws -> Profile {
        let choices = AircProfileColor.choices
        let designed = color.map(Self.designedColor) ?? RGBA(choices[store.state.profiles.count % choices.count])
        var p = try store.createProfile(name: name, emoji: emoji, color: designed)
        if let dir = spareDirectory, !store.storedProfileUses(engineDirectory: dir) {
            try store.updateProfile(p.id) { $0.engineDirectory = dir }
            p.engineDirectory = dir
            spareDirectory = nil
            createdSpares = createdSpares.filter { $0 != dir }
            if let s = spare, s.directory == dir {
                loaded[p.id] = s.profile
                keepLoaded?(s.profile)
                didLoad?(s.profile)
            } else {
                load(p) { _ in }
            }
        } else {
            load(p) { _ in }
        }
        spare = nil
        return p
    }

    /// Profile colours are `AircProfileColor.choices` (design.md §7 "Profile colours", visual review #14). Any other
    /// colour (Arc's pastel swatches from older builds or an import) becomes the nearest choice.
    static func designedColor(_ c: RGBA) -> RGBA {
        let choices = AircProfileColor.choices
        if choices.contains(where: { RGBA($0).hex == c.hex }) { return c }
        return RGBA(choices[AircProfileColor.nearestChoice(to: c.aircColor)])
    }

    /// Converts stored profile colours to the designed ones, once per profile (a converted colour is left alone).
    static func migrateColors(in store: SpacesStore) {
        for p in store.orderedProfiles {
            let c = designedColor(p.color)
            if c.hex != p.color.hex { try? store.updateProfile(p.id) { $0.color = c } }
        }
    }

    /// Deletes spare folders Airc recorded creating that no profile uses and that aren't the current spare (left by a
    /// crash between creating a spare and recording its adoption). Never touches a folder it didn't record.
    func removeOrphanSpares() {
        let current = spareDirectory
        for dir in createdSpares where dir != current {
            if store.storedProfileUses(engineDirectory: dir) {
                createdSpares = createdSpares.filter { $0 != dir }
                continue
            }
            #if canImport(AircCore)
            if let chromium = engine as? ChromiumEngine {
                chromium.deleteUnloadedProfile(directory: dir) { [weak self] result in
                    if result["deleted"] as? Bool == true {
                        self?.createdSpares = self?.createdSpares.filter { $0 != dir } ?? []
                    }
                }
                continue
            }
            #endif
            engine.loadProfile(directory: dir) { [weak self] e in
                guard let self else { return }
                guard let e else { return }
                self.engine.deleteProfile(e) { ok in
                    if ok { self.createdSpares = self.createdSpares.filter { $0 != dir } }
                }
            }
        }
    }

    /// Deletes the profile's browser data, then its record (only once no Space uses it). The record goes only after
    /// the engine deleted the data, so cookies and passwords never stay on disk with nothing pointing at them, and a
    /// profile that isn't loaded is loaded to be deleted (code review M7). Per-profile caches are cleared with it.
    func deleteProfile(_ profileID: String, completion: @escaping (Bool) -> Void) {
        guard case .success = store.canDeleteProfile(profileID), let profile = store.profile(profileID) else {
            return completion(false)
        }
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self, ok else { return completion(false) }
            self.loaded[profileID] = nil
            do { try self.store.deleteProfile(profileID) } catch { return completion(false) }
            SuggestionService.shared.clear(profileID: profileID)
            completion(true)
        }
        if let e = loaded[profileID] { return engine.deleteProfile(e, completion: finish) }
        engine.loadProfile(directory: profile.engineDirectory) { [weak self] e in
            guard let self, let e else { return finish(false) }
            self.engine.deleteProfile(e, completion: finish)
        }
    }
}
